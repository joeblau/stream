#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly ISO_SUSTAINED_DIR="${ISO_SUSTAINED_DIR:-build/isolated-sustained-validation}"
readonly ISO_SUSTAINED_BUILD_PATH="${ISO_SUSTAINED_BUILD_PATH:-$ISO_SUSTAINED_DIR/derived}"
mkdir -p "$ISO_SUSTAINED_DIR"
ruby -ryaml -rjson - "$ISO_SUSTAINED_DIR" <<'RUBY'
# Preserve generated source mtimes across bounded baseline/current comparisons.
class << File
 alias_method :fixture_original_write, :write
 def write(path, content, *args, **options)
  if args.empty? && options.empty? && file?(path) && binread(path).force_encoding(content.encoding)==content
   return content.bytesize
  end
  fixture_original_write(path, content, *args, **options)
 end
end
root=Dir.pwd; folder=File.expand_path(ARGV[0]); spec=YAML.load_file('project.yml')
spec['name']='IsolatedSustainedValidation'
spec['packages'].each_value{|p| p['path']=ENV['STREAM_VENDOR_ROOT'] ? File.join(ENV['STREAM_VENDOR_ROOT'],File.basename(p['path'])) : File.join(root,p['path']) if p['path']}
spec['targets'].select!{|n,_| ['StreamCore','StreamMac'].include?(n)}; spec['schemes']={}
spec['targets'].each_value do |t|
 t['dependencies']&.reject!{|d| d['target'] && !spec['targets'].key?(d['target'])}
 t['sources'].map!{|s| s.is_a?(String) ? File.join(root,s) : s.merge('path'=>File.join(root,s['path']))}
 t.delete('entitlements');t.delete('info')
end
target=spec['targets'].delete('StreamMac');target['type']='tool'
require File.join(root,'scripts/guest_fixture_boundaries')
StreamGuestFixtureBoundaries.apply(spec['targets']['StreamCore'],target,root,folder)
def replace_mac(target,root,folder,name)
 entry=target['sources'].find{|s| s.is_a?(String) && s.end_with?('/'+name)}
 source=File.read(entry || File.join(root,'StreamMac',name))
 if ENV['ISO_SUSTAINED_BASELINE']=='1' && ['CaptureSourcePool.swift','StreamController.swift','IsolatedVideoRecorder.swift','RecordingVideoSourceFactory.swift'].include?(name)
  source=IO.popen(['git','-C',root,'show',"d413aa1:apple/StreamMac/#{name}"], &:read)
  abort 'Historical source unavailable' if source.empty?
  source.gsub!('UserDefaults.standard','GuestFixtureDefaults.value')
  if name=='CaptureSourcePool.swift'
   source.sub!('    init() {', '    private let defaultCameraDeviceID: @MainActor () -> String?\n    init(defaultCameraDeviceID: @escaping @MainActor () -> String? = { AVCaptureDevice.default(for: .video)?.uniqueID }) {\n        self.defaultCameraDeviceID = defaultCameraDeviceID'.gsub('\\n',"\n"))
   source.sub!('guard let resolved = AVCaptureDevice.default(for: .video)?.uniqueID else', 'guard let resolved = defaultCameraDeviceID() else')
   source.sub!('let defaultDevice = AVCaptureDevice.default(for: .video),', 'let defaultDeviceID = defaultCameraDeviceID(),')
   source.sub!('defaultDevice.uniqueID == deviceID', 'defaultDeviceID == deviceID')
  end
 end
 source=yield(source)
 path=File.join(folder,'fixtures','Owned'+name);File.write(path,source)
 target['sources'].delete(entry) if entry
 target['sources'][0]['excludes'] << name
 target['sources'] << path
end
replace_mac(target,root,folder,'StreamController.swift') do |s|
 s.sub!('let capturePool = CaptureSourcePool()','let capturePool = CaptureSourcePool(defaultCameraDeviceID: { OwnedCaptureBoundary.defaultID })') or abort 'Camera construction changed'
 s.sub!('DesktopResilienceCoordinator(url: DesktopStorage.projectDirectory.appendingPathComponent("resilience.json"))','DesktopResilienceCoordinator(url: DesktopStorage.projectDirectory.appendingPathComponent("resilience.json"), observeSystem: false, initialSessionState: .unlocked)') or abort 'Owned initial-lock construction changed'
 s
end
replace_mac(target,root,folder,'MacAudioInput.swift') do |s|
 boundary=/    private nonisolated static func requestMicrophoneAccess\(\) async -> Bool \{.*?\n    \}\n\n    private func configureAndStart/m
 s.sub!(boundary,"    private nonisolated static func requestMicrophoneAccess() async -> Bool { false }\n\n    private func configureAndStart") or abort 'Microphone boundary changed'
 s
end
replace_mac(target,root,folder,'CaptureSourcePool.swift') do |s|
 # Hardware discovery is replaced, not pool identity/demand/recovery logic.
 start=s.index('        switch AVCaptureDevice.authorizationStatus(for: .video)',s.index('    private func startCamera('))
 ending=s.index('        if let deviceID = payload.deviceID {',start)
 abort 'Camera authorization boundary changed' unless start && ending
 s[start...ending]=''
 s.sub!(/            guard let device = AVCaptureDevice\(uniqueID: deviceID\) else \{.*?\n            \}\n.*?            guard !device.isSuspended else \{.*?\n            \}/m,'') or abort 'Camera discovery boundary changed'
 s << <<'SWIFT'

extension CaptureSourcePool {
    func ownedRebuildCameras() { for camera in cameras.values { camera.ownedRebuild() } }
    func ownedDeliverCamera(_ id: String, pixels: CVPixelBuffer?, pts: CMTime) {
        for camera in cameras.values { camera.ownedDeliver(id, pixels: pixels, pts: pts) }
    }
    var ownedCameraBindings: [String] { cameras.values.compactMap(\.ownedIdentity).sorted() }
    var ownedRequestedCount: Int { requested.count }
}
SWIFT
 s
end
replace_mac(target,root,folder,'ScreenSourceCapture.swift') do |s|
 s.sub!('private let picker = SCContentSharingPicker.shared','private lazy var picker = SCContentSharingPicker.shared') or abort 'Picker boundary changed'
 signatures=['init()', 'func pickAndStart(defaults: StreamSettings = .default) async', 'func start(with filter: SCContentFilter,\n               privacy: EffectiveCapturePrivacy = .standard,\n               dynamics: ScreenRegionDynamicsInput? = nil) async', 'func start(matching payload: ScreenSourcePayload,\n               defaults: StreamSettings = .default) async', 'func stop() async','func retire()']
 signatures.each_with_index do |signature,i|
  signature=signature.gsub('\\n',"\n")
  body=i==0 ? '' : i>=4 ? 'isCapturing = false' : 'isCapturing = true; errorMessage = nil'
  pattern=/    #{Regexp.escape(signature)} \{.*?^    \}/m
  s.sub!(pattern,"    #{signature} { #{body} }") or abort "Screen boundary changed: #{signature}"
 end
 s.sub!('    private func stopCurrentStream() async {',"    func ownedDeliver(_ sample: CMSampleBuffer) { if isCapturing { onVideoSample?(sample) } }\n\n    private func stopCurrentStream() async {") or abort 'Screen delivery boundary changed'
 s
end
facecam=File.join(folder,'fixtures/OwnedFacecamCapture.swift')
File.write(facecam,<<'SWIFT')
import AVFoundation
import StreamCore
@MainActor enum OwnedCaptureBoundary { static var defaultID = "owned-camera-A" }
final class FacecamCapture: @unchecked Sendable {
    let latest = LatestCameraFrame()
    private(set) var ownedIdentity: String?
    private var requested: String?
    @MainActor func start(with settings: StreamSettings, deviceUniqueID: String? = nil) {
        requested = deviceUniqueID; ownedRebuild()
    }
    @MainActor func ownedRebuild() { ownedIdentity = requested ?? OwnedCaptureBoundary.defaultID; latest.clear() }
    func setCameraPosition(_ position: CameraPosition) {}
    func stop() { ownedIdentity = nil; latest.clear() }
    func ownedDeliver(_ id: String, pixels: CVPixelBuffer?, pts: CMTime) {
        guard ownedIdentity == id else { return }
        if let pixels { latest.store(pixels, position: .front, presentationTime: pts) } else { latest.clear() }
    }
}
SWIFT
target['sources'].reject!{|s| s.is_a?(String) && s.end_with?('/StreamBroadcast/FacecamCapture.swift')};target['sources'] << facecam
replace_mac(target,root,folder,'IsolatedVideoRecorder.swift'){|s| s}
replace_mac(target,root,folder,'RecordingVideoSourceFactory.swift') do |s|
 if ENV['ISO_SUSTAINED_BASELINE']=='1'
  # Callable signature adapter only; historical rendering still ignores original sourceTime.
  s.gsub!('return { size, pts, duration, sequence, processing in', 'return IsolatedVideoSource.Render { size, pts, duration, sequence, processing, _ in')
 end
 if ENV['ISO_SUSTAINED_DIAGNOSTIC']=='1'
  s.gsub!('            return IsolatedVideoRenderedFrame(sample: frame?.sampleBuffer,', '            if let sample = frame?.sampleBuffer { ISOTimeProbe.shared.video("iso-render-" + source.name, sample: sample) }' + "\n" + '            return IsolatedVideoRenderedFrame(sample: frame?.sampleBuffer,')
 end
 s
end
# Reuse exact decoded-media helpers, without their separate @main entry.
['recording_storage_network_harness.swift','isolated_video_harness.swift'].each do |name|
 source=File.read(File.join(root,'scripts',name)).sub('@main ','')
 source.gsub!('private struct StorageNetworkMedia','struct StorageNetworkMedia')
 source.gsub!('private static func inspect(', 'static func inspect(')
 source.gsub!('size.width == 320 && size.height == 180', 'size.width == 1920 && size.height == 1080')
 path=File.join(folder,'fixtures',name);File.write(path,source);target['sources'] << path
end
target['sources'] += ['isolated_sustained_harness.swift','program_recording_fixtures.swift'].map{|n| File.join(root,'scripts',n)}
spec['targets']['IsolatedSustainedHarness']=target
spec['schemes']['IsolatedSustainedHarness']={'build'=>{'targets'=>{'IsolatedSustainedHarness'=>'all'}}}
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$ISO_SUSTAINED_DIR/project.json" --project "$ISO_SUSTAINED_DIR"
xcodebuild -resolvePackageDependencies -project "$ISO_SUSTAINED_DIR/IsolatedSustainedValidation.xcodeproj" -scheme IsolatedSustainedHarness -derivedDataPath "$ISO_SUSTAINED_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$ISO_SUSTAINED_BUILD_PATH"
xcodebuild -project "$ISO_SUSTAINED_DIR/IsolatedSustainedValidation.xcodeproj" -scheme IsolatedSustainedHarness -destination 'platform=macOS' -derivedDataPath "$ISO_SUSTAINED_BUILD_PATH" CODE_SIGNING_ALLOWED=NO -jobs 2 OTHER_SWIFT_FLAGS='$(inherited) -j2' build
sysctl -n hw.model machdep.cpu.brand_string
sw_vers
xcodebuild -version
env DYLD_FRAMEWORK_PATH="${ISO_SUSTAINED_BUILD_PATH:A}/Build/Products/Debug" python3 - "${ISO_SUSTAINED_BUILD_PATH:A}/Build/Products/Debug/IsolatedSustainedHarness" "${ISO_SUSTAINED_DIR:A}" <<'PY'
import os,pathlib,signal,subprocess,sys,uuid
root=pathlib.Path(sys.argv[2])/('media-'+str(uuid.uuid4()));root.mkdir()
p=subprocess.Popen([sys.argv[1],str(root)],env=os.environ.copy(),start_new_session=True)
try:
 status=p.wait(timeout=300)
 if status==0 and (root/'evidence.json').exists():
  subprocess.run([sys.executable,'scripts/validate_isolated_sustained_metadata.py',str(root)],check=True,env=os.environ.copy())
 raise SystemExit(status)
except subprocess.TimeoutExpired:
 os.killpg(p.pid,signal.SIGTERM)
 try: p.wait(timeout=5)
 except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL);p.wait()
 print('FAIL: owned sustained fixture exceeded 300 seconds; media retained '+str(root),flush=True)
 raise SystemExit(1)
PY
