import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import StreamCore

@main struct ColorTransformHarness {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var settings = ChromaKeySettings(); settings.isEnabled = true
        let started = Date()
        guard let table = ChromaKeyTransform.cubeData(settings: settings) else { fatalError("Cube failed") }
        precondition(table.count == 64*64*64*4*4)
        print("Chroma cube: \(table.count) bytes, \(Date().timeIntervalSince(started)) seconds (CPU prepare, off render thread)")
        // The shipping worker/cache must prepare the same table, never on the render tick.
        for _ in 0..<300 {
            if let cached = ColorCubeCache.shared.chroma(settings) {
                precondition(cached.data == table); break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(ColorCubeCache.shared.chroma(settings) != nil)
        try cpuFixture(settings: settings, directory: directory)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let rect = CGRect(x: 0,y: 0,width: 2,height: 2)
        let control = bytes(CIImage(color: .red).cropped(to: rect), context: context, rect: rect)
        guard control.contains(where: { $0 != 0 }) else {
            print("SKIP: native GPU/CI pixel and sustained-footage validation; solid-red control also renders zero in this sandbox")
            return
        }
        let green = ColorTransformRenderer.key(settings, image: CIImage(color: CIColor(red:0,green:1,blue:0)).cropped(to:rect))
        precondition(bytes(green,context:context,rect:rect).allSatisfy { $0 == 0 }, "Keyed green must be transparent")
        let red = CIImage(color: CIColor(red:1,green:0,blue:0,alpha:0.4)).cropped(to:rect)
        let keyed = bytes(ColorTransformRenderer.key(settings,image:red),context:context,rect:rect)
        precondition(abs(Int(keyed[3])-102) <= 1, "Existing alpha must survive keying")
        var lut = LUTSettings(); lut.assetID = AssetID(); lut.intensity = 1
        let rows = (0..<8).map { "\($0/4) \(($0/2)%2) \($0%2)" }
        let cube = try CubeLUT.parse(Data((["LUT_3D_SIZE 2"]+rows).joined(separator:"\n").utf8))
        let entry = LUTTableStore.Entry(generation: UUID(),cube:cube)
        LUTTableStore.shared.set(entry,for:lut.assetID!)
        for _ in 0..<300 {
            if ColorCubeCache.shared.lut(entry,intensity:1) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let swapped = bytes(ColorTransformRenderer.lut(lut,image:red),context:context,rect:rect)
        precondition(swapped[2] > 98 && swapped[0] < 2 && abs(Int(swapped[3])-102) <= 1,
                     "LUT should map red to blue and preserve alpha")
        lut.isBypassed = true
        precondition(bytes(ColorTransformRenderer.lut(lut,image:red),context:context,rect:rect) == bytes(red,context:context,rect:rect))
        print("PASS: native CI key/alpha, LUT channel ordering/intensity/color space, bypass")
    }

    static func bytes(_ image: CIImage, context: CIContext, rect: CGRect) -> [UInt8] {
        var pixels = [UInt8](repeating:0,count:Int(rect.width*rect.height)*4)
        context.render(image,toBitmap:&pixels,rowBytes:Int(rect.width)*4,bounds:rect,format:.RGBA8,
                       colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
        return pixels
    }
    static func cpuFixture(settings: ChromaKeySettings, directory: URL) throws {
        let width = 640, height = 360
        var before = [UInt8](), after = [UInt8](), composite = [UInt8]()
        var fractional = 0
        for y in 0..<height { for x in 0..<width {
            let dx = (Double(x)-320)/100, dy = (Double(y)-180)/135
            let radial = sqrt(dx*dx+dy*dy)
            let edge = min(1,max(0,(1.02-radial)/0.08))
            let foreground = SIMD3<Double>(0.63,0.35,0.22)
            let screen = SIMD3<Double>(0.02,0.65+0.3*Double(x)/Double(width),0.01)
            let color = foreground*edge+screen*(1-edge)
            let transformed = ChromaKeyTransform.rgba(color,settings:settings)
            if transformed.w > 0 && transformed.w < 1 { fractional += 1 }
            let bg = SIMD3<Double>(0.1,0.2,0.7)
            let blended = SIMD3(transformed.x,transformed.y,transformed.z)+bg*(1-transformed.w)
            before += rgba(SIMD4(color.x,color.y,color.z,1))
            after += rgba(transformed)
            composite += rgba(SIMD4(blended.x,blended.y,blended.z,1))
        } }
        precondition(fractional > 100, "Soft edges must retain useful fractional alpha")
        try save(before,width:width,height:height,to:directory.appendingPathComponent("before.png"))
        try save(after,width:width,height:height,to:directory.appendingPathComponent("keyed.png"))
        try save(composite,width:width,height:height,to:directory.appendingPathComponent("composite.png"))
        print("PASS: CPU reference fixture, \(fractional) fractional-alpha edge pixels, premultiplied background composition")
    }
    static func rgba(_ c: SIMD4<Double>) -> [UInt8] {
        [c.x,c.y,c.z,c.w].map { UInt8(min(255,max(0,($0*255).rounded()))) }
    }
    static func save(_ bytes:[UInt8],width:Int,height:Int,to url:URL) throws {
        let image = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
                            space:CGColorSpace(name:CGColorSpace.sRGB)!,
                            bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let target = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(target,image,nil)
        guard CGImageDestinationFinalize(target) else { throw CocoaError(.fileWriteUnknown) }
    }
}
