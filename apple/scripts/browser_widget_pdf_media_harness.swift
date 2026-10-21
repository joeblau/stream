import AppKit
import Foundation
import WebKit
@MainActor private final class MediaNavigation: NSObject,WKNavigationDelegate {
 var done:CheckedContinuation<Void,Error>?
 func load(_ v:WKWebView,_ url:URL) async throws { try await withCheckedThrowingContinuation { done=$0;v.loadFileURL(url,allowingReadAccessTo:url.deletingLastPathComponent()) } }
 func webView(_ v:WKWebView,didFinish n:WKNavigation!) { done?.resume();done=nil }
 func webView(_ v:WKWebView,didFailProvisionalNavigation n:WKNavigation!,withError e:Error) { done?.resume(throwing:e);done=nil }
}
private func pixels(_ image:CGImage,_ x:Int,_ y:Int)->[UInt8] {
 var bytes=[UInt8](repeating:0,count:480*270*4)
 return bytes.withUnsafeMutableBytes { p in
  let c=CGContext(data:p.baseAddress,width:480,height:270,bitsPerComponent:8,bytesPerRow:480*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue)!
  c.draw(image,in:CGRect(x:0,y:0,width:480,height:270));let at=(y*480+x)*4;return Array(p.bindMemory(to:UInt8.self)[at..<at+4])
 }
}
@main @MainActor struct BrowserWidgetPDFMediaHarness {
 static func image(_ v:WKWebView,_ pdf:Bool) async throws ->CGImage {
  if pdf { return try await withCheckedThrowingContinuation { c in BrowserWidgetRasterizer.capture(v,width:480,height:270,isCurrent:{true}) { c.resume(with:$0.mapError { $0 as Error }) } } }
  return try await withCheckedThrowingContinuation { c in
   let config=WKSnapshotConfiguration();config.snapshotWidth=480;config.afterScreenUpdates=true
   v.takeSnapshot(with:config) { image,error in if let g=image?.cgImage(forProposedRect:nil,context:nil,hints:nil){c.resume(returning:g)}else{c.resume(throwing:error ?? NSError(domain:"snapshot",code:1))} }
  }
 }
 static func main(){setbuf(stdout,nil);let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
  Task{do{try await run();exit(0)}catch{print("FAIL: \(error)");exit(1)}}
  DispatchQueue.main.asyncAfter(deadline:.now()+30){print("FAIL: deadline");exit(2)};app.run()
 }
 static func run() async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
  let html="""
  <style>html,body{margin:0;background:transparent}video,canvas,#animated{position:absolute;top:20px;width:80px;height:80px}video{left:20px}canvas{left:120px}#animated{left:220px;background:red;animation:color .4s steps(1) infinite}@keyframes color{50%{background:blue}}</style>
  <video id=video muted loop playsinline preload=auto src=owned.mp4></video><canvas id=gl width=80 height=80></canvas><div id=animated></div><canvas id=glDefault width=80 height=80 style=left:320px></canvas>
  <script>window.context=gl.getContext('webgl',{preserveDrawingBuffer:true});if(context){context.clearColor(0,1,0,1);context.clear(context.COLOR_BUFFER_BIT);context.flush();}window.defaultContext=glDefault.getContext('webgl');window.defaultSamples=0;if(defaultContext){const draw=t=>{const cyan=Math.floor(t/200)%2===0;defaultContext.clearColor(cyan?0:1,cyan?1:0,cyan?1:0,1);defaultContext.clear(defaultContext.COLOR_BUFFER_BIT);defaultContext.flush();defaultSamples++;requestAnimationFrame(draw)};requestAnimationFrame(draw)}</script>
  """
  let url=root.appendingPathComponent("owned.html");try Data(html.utf8).write(to:url)
  let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent();config.mediaTypesRequiringUserActionForPlayback=[]
  let v=WKWebView(frame:CGRect(x:0,y:0,width:480,height:270),configuration:config);v.underPageBackgroundColor = .clear
  let w=NSWindow(contentRect:v.bounds,styleMask:.borderless,backing:.buffered,defer:false);w.isOpaque=false;w.backgroundColor = .clear;w.alphaValue = 0.01;w.contentView=v;w.orderFrontRegardless()
  let navigation=MediaNavigation();v.navigationDelegate=navigation;try await navigation.load(v,url)
  for _ in 0..<100 { if try await v.evaluateJavaScript("video.readyState>=2") as? Bool == true {break};try await Task.sleep(for:.milliseconds(20)) }
  guard try await v.evaluateJavaScript("!!window.context && !!window.defaultContext") as? Bool == true else { print("UNQUALIFIED: actual WebGL contexts unavailable on this host"); exit(77) }
  for t in [0.2,1.2] {
   _ = try await v.evaluateJavaScript("video.pause();video.currentTime=\(t)")
   try await Task.sleep(for:.milliseconds(150))
   for pdf in [false,true] {let i=try await image(v,pdf);let vp=pixels(i,40,40);precondition(t<1 ? vp[2]>200 && vp[0]<50 : vp[0]>200 && vp[2]<50,"Actual seeked HTML video frame omitted");precondition(pixels(i,140,40)[1]>230,"Actual preserved WebGL omitted");print("SEEK \(t) \(pdf ? "pdf":"snapshot") video=\(pixels(i,40,40)) GL=\(pixels(i,140,40)) CSS=\(pixels(i,240,40)) defaultAnimatedGL=\(pixels(i,340,40))");let rep=NSBitmapImageRep(cgImage:i);try rep.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("seek-\(t)-\(pdf).png"))}
  }
  _ = try await v.evaluateJavaScript("context.clearColor(0,0,1,1);context.clear(context.COLOR_BUFFER_BIT);context.flush();video.currentTime=0;video.play();'playing'")
  var redVideo=0,blueVideo=0,redCSS=0,blueCSS=0,redGL=0,cyanGL=0
  for n in 0..<20 {
   try await Task.sleep(for:.milliseconds(100));let t=try await v.evaluateJavaScript("video.currentTime")
   let i=try await image(v,true)
   let vp=pixels(i,40,40),css=pixels(i,240,40),gl=pixels(i,340,40)
   if vp[2]>200 && vp[0]<50 {redVideo+=1};if vp[0]>200 && vp[2]<50 {blueVideo+=1}
   if css[2]>230 && css[0]<25 {redCSS+=1};if css[0]>230 && css[2]<25 {blueCSS+=1}
   if gl[2]>230 && gl[0]<25 {redGL+=1};if gl[0]>230 && gl[1]>230 && gl[2]<25 {cyanGL+=1}
   precondition(pixels(i,140,40)[0]>230 && pixels(i,140,40)[2]<25,"Script-updated preserved WebGL frame omitted")
   print("LIVE \(n) time=\(t) video=\(pixels(i,40,40)) GL=\(pixels(i,140,40)) CSS=\(pixels(i,240,40)) defaultAnimatedGL=\(pixels(i,340,40))")
  }
  precondition(redVideo>3 && blueVideo>3 && redCSS>3 && blueCSS>3 && redGL>3 && cyanGL>3,"Actual live video/CSS/default-buffer WebGL content did not advance")
  _ = try await v.evaluateJavaScript("video.pause()");w.close()
  print("PASS: actual seeked/live muted H264 HTML video, script-updated preserved WebGL, running default-buffer WebGL and CSS animation reflected by public PDF; no private API/capture permissions/audio activation")
 }
}
