import Combine
import CoreImage
import Foundation
import StreamCore
import os.lock

/// Immutable prepared tables shared by preview/program. All file parsing and
/// cube generation happens off the render tick, with bounded pending work and
/// a 64 MiB LRU cache. Missing/loading/invalid tables render the original.
final class ColorCubeCache: @unchecked Sendable {
    static let shared = ColorCubeCache()
    struct Table: Sendable { var dimension: Int; var data: Data }
    private enum Key: Hashable, Sendable { case chroma(ChromaKeySettings); case lut(UUID, Double) }
    private var lock = os_unfair_lock_s()
    private var tables: [Key: Table] = [:]
    private var order: [Key] = []
    private var pending = Set<Key>()
    private var bytes = 0
    private let worker = DispatchQueue(label: "stream.color-cubes", qos: .userInitiated)

    func chroma(_ input: ChromaKeySettings) -> Table? {
        var settings = input
        settings.left = 0; settings.right = 0; settings.top = 0; settings.bottom = 0; settings.maskFeather = 0
        let configuration = settings
        let key = Key.chroma(configuration)
        return table(key) { ChromaKeyTransform.cubeData(settings: configuration).map { Table(dimension: 64, data: $0) } }
    }
    func lut(_ entry: LUTTableStore.Entry, intensity: Double) -> Table? {
        table(.lut(entry.generation, intensity)) {
            entry.cube.rgbaData(intensity: intensity).map { Table(dimension: entry.cube.dimension, data: $0) }
        }
    }
    private func table(_ key: Key, prepare: @escaping @Sendable () -> Table?) -> Table? {
        os_unfair_lock_lock(&lock)
        if let cached = tables[key] {
            order.removeAll { $0 == key }; order.append(key)
            os_unfair_lock_unlock(&lock)
            return cached
        }
        guard !pending.contains(key), pending.count < 4 else { os_unfair_lock_unlock(&lock); return nil }
        pending.insert(key)
        os_unfair_lock_unlock(&lock)
        worker.async { [self] in
            let generated = prepare()
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            pending.remove(key)
            guard let generated else { return }
            while (bytes + generated.data.count > 64*1024*1024 || tables.count >= 32), let first = order.first {
                order.removeFirst(); bytes -= tables.removeValue(forKey: first)?.data.count ?? 0
            }
            tables[key] = generated; order.append(key); bytes += generated.data.count
        }
        return nil
    }
}

final class LUTTableStore: @unchecked Sendable {
    static let shared = LUTTableStore()
    struct Entry: Sendable { let generation: UUID; let cube: CubeLUT }
    private var lock = os_unfair_lock_s()
    private var entries: [AssetID: Entry] = [:]
    func entry(_ id: AssetID) -> Entry? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return entries[id]
    }
    func set(_ entry: Entry?, for id: AssetID) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; entries[id] = entry
    }
}

@MainActor final class LUTLibraryController: ObservableObject {
    enum Status: Equatable { case loading, ready(Int), failed(String) }
    @Published private(set) var statuses: [AssetID: Status] = [:]
    private var signatures: [AssetID: LibraryAsset] = [:]
    private var generations: [AssetID: UUID] = [:]
    private var latestIDs = Set<AssetID>()
    private var pendingLoads = 0

    func sync(ids: Set<AssetID>, library: AssetLibraryStore) {
        latestIDs = ids
        let allowed = Set(ids.sorted(by: { $0.description < $1.description }).prefix(32))
        for id in signatures.keys where !allowed.contains(id) {
            signatures[id] = nil; generations[id] = nil; statuses[id] = nil
            LUTTableStore.shared.set(nil, for: id)
        }
        // Bound source-table memory too; a show may store many unused presets.
        for id in allowed {
            guard let asset = library.asset(withID: id) else {
                statuses[id] = .failed("LUT asset is missing. Restore it in Assets.")
                signatures[id] = nil; generations[id] = nil
                LUTTableStore.shared.set(nil, for: id)
                continue
            }
            if case .missing(let reason) = library.availability(of: id) {
                statuses[id] = .failed("LUT is unavailable: \(reason). Restore it in Assets.")
                signatures[id] = nil; generations[id] = nil
                LUTTableStore.shared.set(nil, for: id)
                continue
            }
            guard signatures[id] != asset else { continue }
            guard pendingLoads < 4 else { continue }
            signatures[id] = asset
            let generation = UUID(); generations[id] = generation
            guard let access = library.access(for: id), access.isAccessible else {
                statuses[id] = .failed("LUT could not be opened. Relink it in Assets.")
                LUTTableStore.shared.set(nil, for: id)
                continue
            }
            statuses[id] = .loading
            LUTTableStore.shared.set(nil, for: id)
            pendingLoads += 1
            Task { [weak self] in
                let result: Result<CubeLUT, Error> = await Task.detached(priority: .userInitiated) {
                    Result {
                        let file = try FileHandle(forReadingFrom: access.url)
                        defer { try? file.close(); withExtendedLifetime(access) {} }
                        return try CubeLUT.parse(file.read(upToCount: CubeLUT.maxFileBytes+1) ?? Data())
                    }
                }.value
                guard let self else { return }
                self.pendingLoads -= 1
                guard self.generations[id] == generation else {
                    self.sync(ids: self.latestIDs, library: library); return
                }
                switch result {
                case .success(let cube):
                    LUTTableStore.shared.set(.init(generation: generation, cube: cube), for: id)
                    self.statuses[id] = .ready(cube.dimension)
                case .failure(let error): self.statuses[id] = .failed(String(describing: error))
                }
                self.sync(ids: self.latestIDs, library: library)
            }
        }
        for id in ids where !allowed.contains(id) { statuses[id] = .failed("A show can load up to 32 LUT assets at once.") }
        for id in statuses.keys where !ids.contains(id) { statuses[id] = nil }
    }
}

/// Effects run in source coordinates before framing. The LUT follows the
/// existing picture adjustments, in explicitly selected sRGB/linear-sRGB.
enum ColorTransformRenderer {
    static func key(_ settings: ChromaKeySettings, image: CIImage) -> CIImage {
        guard settings.isEnabled, !settings.isBypassed, settings.validationError == nil,
              let table = ColorCubeCache.shared.chroma(settings) else { return image }
        var output = cube(table, colorSpace: .sRGB, image: image)
        let e = image.extent
        let rect = CGRect(x: e.minX+e.width*settings.left, y: e.minY+e.height*settings.bottom,
                          width: e.width*(1-settings.left-settings.right), height: e.height*(1-settings.top-settings.bottom))
        if rect != e {
            var mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: rect), "inputRadius": 0,
                "inputColor": CIColor.white])?.outputImage ?? CIImage(color: .white).cropped(to: rect)
            if settings.maskFeather > 0 { mask = mask.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": settings.maskFeather]) }
            mask = mask.cropped(to: e)
            output = output.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: e), kCIInputMaskImageKey: mask])
        }
        return output.cropped(to: e)
    }
    static func lut(_ settings: LUTSettings, image: CIImage) -> CIImage {
        guard settings.isEnabled, let id = settings.assetID, let entry = LUTTableStore.shared.entry(id),
              let table = ColorCubeCache.shared.lut(entry, intensity: settings.intensity) else { return image }
        return cube(table, colorSpace: settings.colorSpace, image: image).cropped(to: image.extent)
    }
    private static func cube(_ table: ColorCubeCache.Table, colorSpace: LUTColorSpace, image: CIImage) -> CIImage {
        let color = CGColorSpace(name: colorSpace == .sRGB ? CGColorSpace.sRGB : CGColorSpace.linearSRGB)!
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": table.dimension, "inputCubeData": table.data, "inputColorSpace": color])
    }
}
