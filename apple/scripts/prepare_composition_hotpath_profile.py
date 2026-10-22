#!/usr/bin/env python3
"""Generate counter-instrumented copies for bounded same-content attribution.

The shipping sources and sustained workload duration/gates are never edited.
The generated tool runs exactly 20 seconds each at 1080p30, retains the recorder
and deliberate slow sink, and makes no sustained qualification claim.
"""
import argparse,hashlib,os,pathlib,shutil,json,subprocess
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-root',type=pathlib.Path,default=pathlib.Path(__file__).resolve().parents[1])
parser.add_argument('--output',type=pathlib.Path)
args=parser.parse_args();root=args.source_root.resolve();build=(args.output or root/'build/composition-hotpath-profile').resolve();src=build/'StreamMac'
assert src != root/'StreamMac', 'Generated source must not replace shipping source'
build.mkdir(parents=True,exist_ok=True)
marker=build/'.composition-hotpath-generated'
if src.exists() and not marker.exists(): raise SystemExit('Refusing to replace unmarked source directory: '+str(src))
if src.exists(): shutil.rmtree(src)
marker.write_text('Generated counter-only source copies; shipping sources are untouched.\n')

shutil.copytree(root/'StreamMac',src,dirs_exist_ok=True)
def edit(file,old,new,count=1):
 p=src/file;s=p.read_text();assert s.count(old)==count,(file,old,s.count(old));p.write_text(s.replace(old,new))
profile='''import Foundation
import CryptoKit
import CoreVideo
final class CompositionHotPathProfile: @unchecked Sendable {
    static let shared = CompositionHotPathProfile()
    private let lock = NSLock()
    private var entries: [String: [Double]] = [:]
    private var labels: [UUID: String] = [:]
    private var pixelHash: String?
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }
    func label(_ id: UUID, _ name: String) { lock.lock(); labels[id] = name; lock.unlock() }
    func name(_ id: UUID) -> String { lock.lock(); defer { lock.unlock() }; return labels[id] ?? "other" }
    func record(_ name: String, since: Double) { recordValue(name, (Self.now()-since)*1000) }
    func recordValue(_ name: String, _ ms: Double) { lock.lock(); entries[name, default: []].append(ms); lock.unlock() }
    func count(_ name: String) { recordValue(name, 0) }
    func hash(_ image: CVPixelBuffer?) {
        guard let image else { return }
        lock.lock(); let needed = pixelHash == nil; if needed { pixelHash = "pending" }; lock.unlock()
        guard needed else { return }
        let t = Self.now(); CVPixelBufferLockBaseAddress(image, .readOnly)
        var bytes = Data(); let base = CVPixelBufferGetBaseAddress(image)!; let rowBytes = CVPixelBufferGetBytesPerRow(image)
        for row in 0..<CVPixelBufferGetHeight(image) { bytes.append(base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self), count: CVPixelBufferGetWidth(image) * 4) }
        let value = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        CVPixelBufferUnlockBaseAddress(image, .readOnly)
        lock.lock(); pixelHash = value; lock.unlock(); record("oneTimePixelHash", since: t)
    }
    func reset() { lock.lock(); entries.removeAll(); labels.removeAll(); pixelHash=nil; lock.unlock() }
    func write(_ url: URL, caseIndex: Int) throws {
        lock.lock(); let values=entries; let hash=pixelHash; lock.unlock()
        var result: [String: Any] = [:]
        for (key, samples) in values {
            let ordered=samples.sorted(); let count=ordered.count; let sum=ordered.reduce(0,+)
            var item: [String:Any] = [:]
            item["count"]=count; item["sumMilliseconds"]=sum; item["meanMilliseconds"]=sum/Double(count)
            item["medianMilliseconds"]=ordered[count/2]; item["p95Milliseconds"]=ordered[Int(Double(count-1)*0.95)]
            item["p99Milliseconds"]=ordered[Int(Double(count-1)*0.99)]; item["maxMilliseconds"]=ordered.last!
            item["over33ms"]=ordered.filter{$0>33.333}.count; item["over100ms"]=ordered.filter{$0>100}.count
            result[key]=item
        }
        let object: [String:Any] = ["sourceIdentity":"see profile-source-hashes.json; source may contain local changes","case":caseIndex,"seconds":20,"canvas":"1920x1080","fps":30,"layers":12,"firstWarmPixelSHA256":hash ?? "missing","scope":"Instrumented bounded local attribution only; not sustained capacity qualification. No waveform, physical source or hosted-VM qualification.","spans":result]
        try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
    }
}
'''
(src/'CompositionHotPathProfile.swift').write_text(profile)
edit('SceneRenderer.swift','        let outWidth = Int(canvasSize.width.rounded())','        let profileStarted = CompositionHotPathProfile.now()\n        defer { CompositionHotPathProfile.shared.record("rendererTotal", since: profileStarted) }\n        let graphStarted = CompositionHotPathProfile.now()\n        let outWidth = Int(canvasSize.width.rounded())',2)
edit('SceneRenderer.swift','        return finish(output, canvas: canvas, width: outWidth, height: outHeight,','        CompositionHotPathProfile.shared.record("sceneGraphPreparation", since: graphStarted)\n        return finish(output, canvas: canvas, width: outWidth, height: outHeight,',2)
edit('SceneRenderer.swift','        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(\n            kCFAllocatorDefault, pool, allocationLimit, &out\n        ) == kCVReturnSuccess, let outBuffer = out else { return nil }','        let poolStarted = CompositionHotPathProfile.now()\n        let poolStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, allocationLimit, &out)\n        CompositionHotPathProfile.shared.record("poolAllocation", since: poolStarted)\n        guard poolStatus == kCVReturnSuccess, let outBuffer = out else { CompositionHotPathProfile.shared.count("poolFailure.\\(poolStatus)"); return nil }\n        let ciStarted = CompositionHotPathProfile.now()')
edit('SceneRenderer.swift','        guard let sample = makeSampleBuffer(from: outBuffer,','        CompositionHotPathProfile.shared.record(completedRenderCount % 30 == 1 ? "ciRender.sampledTaskWait" : "ciRender.regular", since: ciStarted)\n        let wrapStarted = CompositionHotPathProfile.now()\n        defer { CompositionHotPathProfile.shared.record("sampleWrapAndChat", since: wrapStarted) }\n        guard let sample = makeSampleBuffer(from: outBuffer,')
edit('SceneRenderer.swift','    private func placeText(_ text: TextSourcePayload, layer: LayerNode, canvas: CGRect) -> CIImage? {','    private func placeText(_ text: TextSourcePayload, layer: LayerNode, canvas: CGRect) -> CIImage? {\n        let textStarted = CompositionHotPathProfile.now()\n        defer { CompositionHotPathProfile.shared.record("titleTotal", since: textStarted) }')
font_line=('        var selectedFont = titleFonts.resolve(requested: text.fontName, size: scaledFontSize)' if 'var selectedFont = titleFonts.resolve' in (src/'SceneRenderer.swift').read_text() else '        var font = TitleFontFallback.makeFont(requested: text.fontName, size: scaledFontSize)')
edit('SceneRenderer.swift',font_line,'        let fontStarted = CompositionHotPathProfile.now()\n'+font_line+'\n        CompositionHotPathProfile.shared.record("titleFontCascade", since: fontStarted)')
edit('SceneRenderer.swift','        if let cached = generatedCache[key] { return cached }','        if let cached = generatedCache[key] { CompositionHotPathProfile.shared.count(key.descriptor.hasPrefix("text") ? "generatedRasterHit.title" : "generatedRasterHit.shape"); return cached }\n        CompositionHotPathProfile.shared.count(key.descriptor.hasPrefix("text") ? "generatedRasterMiss.title" : "generatedRasterMiss.shape")')
edit('CompositionEngine.swift','        let renderStarted = ProcessInfo.processInfo.systemUptime','        let renderStarted = ProcessInfo.processInfo.systemUptime\n        defer { CompositionHotPathProfile.shared.record("tickTotal", since: renderStarted) }')
edit('CompositionEngine.swift','    private var drops = 0','    private var drops = 0\n    private let profileName: String')
edit('CompositionEngine.swift','        self.capacity = max(1, capacity)','        self.profileName = CompositionHotPathProfile.shared.name(token)\n        self.capacity = max(1, capacity)')
edit('CompositionEngine.swift','    func post(_ frame: CompositedFrame) {\n        os_unfair_lock_lock(&lock)','    func post(_ frame: CompositedFrame) {\n        let postStarted = CompositionHotPathProfile.now()\n        os_unfair_lock_lock(&lock)\n        let lockAcquired = CompositionHotPathProfile.now()')
edit('CompositionEngine.swift','        os_unfair_lock_unlock(&lock)\n        if shouldSchedule {','        os_unfair_lock_unlock(&lock)\n        CompositionHotPathProfile.shared.recordValue("mailboxLockWait." + profileName, (lockAcquired-postStarted)*1000)\n        CompositionHotPathProfile.shared.record("mailboxPost." + profileName, since: postStarted)\n        if shouldSchedule {')
edit('CompositionEngine.swift','            sink(frame)','            let sinkStarted = CompositionHotPathProfile.now()\n            sink(frame)\n            CompositionHotPathProfile.shared.record("mailboxSink." + profileName, since: sinkStarted)')
harness=(root/'scripts/studio_performance_harness.swift').read_text()
harness=harness.replace('let sustained = CommandLine.arguments.contains("--sustained")','let sustained = true')
harness=harness.replace('let requestedSeconds = ProcessInfo.processInfo.environment["STUDIO_PERFORMANCE_SECONDS"].flatMap(Double.init) ?? 180','let requestedSeconds = 20.0')
harness=harness.replace('(120...600).contains(requestedSeconds)','requestedSeconds == 20')
harness=harness.replace('            let replay = PerformanceOwnedReplay()','            CompositionHotPathProfile.shared.reset()\n            let replay = PerformanceOwnedReplay()')
harness=harness.replace('            await engine.addSink(token: token, capacity: 2)','            CompositionHotPathProfile.shared.label(token, "healthyRecording")\n            await engine.addSink(token: token, capacity: 2)')
harness=harness.replace('                probe.receive(frame, warmingFrames: fps, recording: recording)','                probe.receive(frame, warmingFrames: fps, recording: recording)\n                if frame.sequence > fps { CompositionHotPathProfile.shared.hash(frame.pixelBuffer) }')
harness=harness.replace('            await engine.addSink(token: UUID(), capacity: 1)','            let slowToken=UUID(); CompositionHotPathProfile.shared.label(slowToken, "deliberate80ms")\n            await engine.addSink(token: slowToken, capacity: 1)')
harness=harness.replace('            previousRecording = url','            try CompositionHotPathProfile.shared.write(directory.appendingPathComponent("hotpath-case-\\(caseIndex).json"), caseIndex: caseIndex)\n            previousRecording = url')
harness=harness.replace('        let failures = results.flatMap(\\.checks).filter { $0.status == .failed }','        let failures: [PerformanceWorkloadCheck] = [] // Bounded attribution never claims sustained qualification. Original raw checks remain in reports.')
# Match the scheduling and fixture-phase spans used in the retained trace.
edit('CompositionEngine.swift','            while !Task.isCancelled {\n                await self?.tick()', '            while !Task.isCancelled {\n                let lateness=deadline.duration(to: clock.now).components\n                CompositionHotPathProfile.shared.recordValue("tickStartDeadlineLateness", max(0, Double(lateness.seconds)*1000 + Double(lateness.attoseconds)/1e15))\n                await self?.tick()')
edit('CompositionEngine.swift','                if next.skipped > 0 { await self?.noteMissedDeadlines(next.skipped) }','                if next.skipped > 0 { await self?.noteMissedDeadlines(next.skipped) }\n                CompositionHotPathProfile.shared.recordValue("skippedSlotsEquivalentMilliseconds", Double(next.skipped)*1000/30.0)')
edit('CompositionEngine.swift','                    await Task.yield()','                    let yieldStarted=CompositionHotPathProfile.now()\n                    await Task.yield()\n                    CompositionHotPathProfile.shared.record("overdueYieldWait", since: yieldStarted)')
harness=harness.replace('                    let sample = try ProgramRecordingFixtures.audio(at:', '                    let pcmStarted=CompositionHotPathProfile.now()\n                    let sample = try ProgramRecordingFixtures.audio(at:')
harness=harness.replace('                    recording.appendAudio(timed)','                    recording.appendAudio(timed)\n                    CompositionHotPathProfile.shared.record("fixturePCMGenerateAndEnqueue", since: pcmStarted)')
harness=harness.replace('                    let sample = sampler.sample(', '                    let sampleStarted=CompositionHotPathProfile.now()\n                    let sample = sampler.sample(')
harness=harness.replace('                    resources.append(sample); lastResourceTime = sample.uptime','                    resources.append(sample); lastResourceTime = sample.uptime\n                    CompositionHotPathProfile.shared.record("fixtureResourceSample", since: sampleStarted)')
harness=harness.replace('Sustained owned static/layer and actual H.264 replay/encoding workloads;','Bounded 20-second instrumentation trace only, not sustained capacity qualification; same generated content;')
harness=harness.replace(r'print("PASS: \(sustained ? "sustained owned media" : "short smoke") workload checks and observations persisted. Artifacts: \(directory.path)")',r'print("TRACE COMPLETE: bounded 20s/case attribution only, no sustained qualification. Artifacts: \(directory.path)")')

(build/'hotpath_harness.swift').write_text(harness)
# Generate the same tool dependency graph; only the StreamMac/harness source copies are instrumented.
ruby='''require 'yaml';require 'json';root=ARGV[0];folder=ARGV[1];spec=YAML.load_file(File.join(root,'project.yml'));spec['name']='CompositionHotPathProfile';spec['packages'].each_value{|p|p['path']=File.join(ENV.fetch('STREAM_VENDOR_ROOT',File.join(root,'Vendor')),File.basename(p['path'])) if p['path']};spec['targets'].select!{|name,_|['StreamCore','StreamMac'].include?(name)};spec['targets'].each_value{|t|t['dependencies']&.reject!{|d|d['target']&&!spec['targets'].key?(d['target'])};t['sources'].map!{|s|s.is_a?(String) ? File.join(root,s) : s.merge('path'=>File.join(root,s['path']))};t.delete('entitlements')};spec['schemes']={};h=spec['targets'].delete('StreamMac');h['type']='tool';h['sources'][0]={'path'=>File.join(folder,'StreamMac'),'excludes'=>['StreamMacApp.swift']};h['sources']<<File.join(folder,'hotpath_harness.swift');['program_recording_fixtures.swift','performance_owned_replay.swift','performance_workload_evidence.swift'].each{|s|h['sources']<<File.join(root,'scripts',s)};spec['targets']['StudioPerformanceHarness']=h;spec['schemes']['StudioPerformanceHarness']={'build'=>{'targets'=>{'StudioPerformanceHarness'=>'all'}}};require File.join(root,'scripts/desktop_transport_fixture');StreamDesktopTransportFixture.apply(h,root);File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))'''
subprocess.run(['ruby','-e',ruby,str(root),str(build)],check=True)
manifest={'baseCommit':subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip(),'sourceSHA256':{},'generatedSHA256':{},'qualification':False,'secondsPerCase':20,'scope':'Only bounded local attribution. Lookup count is not a measured cache-miss/builder count.'}
for path in [root/'StreamMac/CompositionEngine.swift',root/'StreamMac/SceneRenderer.swift',root/'StreamMac/TitleRenderFontCache.swift',root/'scripts/studio_performance_harness.swift']:
 if path.exists(): manifest['sourceSHA256'][str(path.relative_to(root))]=hashlib.sha256(path.read_bytes()).hexdigest()
for path in [src/'CompositionEngine.swift',src/'SceneRenderer.swift',src/'CompositionHotPathProfile.swift',build/'hotpath_harness.swift']:
 manifest['generatedSHA256'][str(path.relative_to(build))]=hashlib.sha256(path.read_bytes()).hexdigest()
(build/'profile-source-hashes.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(build)
