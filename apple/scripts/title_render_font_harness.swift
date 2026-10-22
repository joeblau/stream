import Foundation
import CoreText
import CoreMedia
import CoreVideo
import CryptoKit
import StreamCore

/// The runner inserts this call only into its generated cache-source copy.
/// Shipping font lookup has no callback, tracing or registration seam.
final class TitleFontEpochFixture: @unchecked Sendable {
    static let shared = TitleFontEpochFixture()
    var afterBuild: (() -> Void)?
    var buildCount = 0
    func fontBuilt() { buildCount += 1; afterBuild?() }
}

enum TitleFontPixelRegression {
    static let size=CGSize(width:1920,height:1080)
    static let frames=SourceFrameLookup(camera:{_ in nil},screen:{_ in nil})
    static func pixels(_ frame:CompositedFrame?)->Data {
        precondition(frame != nil,"Actual native renderer must produce a frame")
        let pixel=frame!.pixelBuffer!;CVPixelBufferLockBaseAddress(pixel,.readOnly);defer{CVPixelBufferUnlockBaseAddress(pixel,.readOnly)}
        var bytes=Data();let base=CVPixelBufferGetBaseAddress(pixel)!;let rowBytes=CVPixelBufferGetBytesPerRow(pixel)
        for row in 0..<CVPixelBufferGetHeight(pixel){bytes.append(base.advanced(by:row*rowBytes).assumingMemoryBound(to:UInt8.self),count:CVPixelBufferGetWidth(pixel)*4)}
        return bytes
    }
    static func hash(_ bytes:Data)->String {SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
    static func scene(_ text:TextSourcePayload)->Scene {
        Scene(name:"Actual title output",layers:[LayerNode(name:"Title",payload:.text(text),transform:LayerTransform(position:GraphPoint(x:0.1,y:0.2),size:GraphSize(width:0.7,height:0.5),anchor:.topLeft))],background:.solid(colorHex:"#204060"))
    }
    static func render(_ renderer:SceneRenderer,_ scene:Scene,_ registry:[SceneID:Scene]=[:],transition:Bool=false)->Data {
        autoreleasepool {
            if transition{return pixels(renderer.renderTransition(from:scene,to:scene,blend:.init(style:.dissolve,progress:0.5,direction:.left,dipColorHex:"#000000"),overlayContext:.empty,canvasSize:size,frames:frames,sourcePayloads:[:],scenes:registry,presentationTime:CMTime(seconds:100,preferredTimescale:48000),frameDuration:CMTime(value:1,timescale:30),sequence:1))}
            return pixels(renderer.render(scene:scene,overlayContext:.empty,canvasSize:size,frames:frames,sourcePayloads:[:],scenes:registry,presentationTime:CMTime(seconds:100,preferredTimescale:48000),frameDuration:CMTime(value:1,timescale:30),sequence:1))
        }
    }
    static func reference(_ renderer:BaselineSceneRenderer,_ scene:Scene,_ registry:[SceneID:Scene]=[:],transition:Bool=false)->Data {
        autoreleasepool {
            if transition{return pixels(renderer.renderTransition(from:scene,to:scene,blend:.init(style:.dissolve,progress:0.5,direction:.left,dipColorHex:"#000000"),overlayContext:.empty,canvasSize:size,frames:frames,sourcePayloads:[:],scenes:registry,presentationTime:CMTime(seconds:100,preferredTimescale:48000),frameDuration:CMTime(value:1,timescale:30),sequence:1))}
            return pixels(renderer.render(scene:scene,overlayContext:.empty,canvasSize:size,frames:frames,sourcePayloads:[:],scenes:registry,presentationTime:CMTime(seconds:100,preferredTimescale:48000),frameDuration:CMTime(value:1,timescale:30),sequence:1))
        }
    }
    static func run(_ output:URL)throws {
        let optimized=SceneRenderer();let original=BaselineSceneRenderer();var receipt:[String:String]=[:]
        let cases:[(String,TextSourcePayload)]=[
            ("static",.init(text:"Workload title 0",fontSize:30)),
            ("unicode",.init(text:"Café 👩🏽‍🚀 中文 العربية",fontSize:52)),
            ("missingFont",.init(text:"Fallback Café 中文",fontName:"Stream Missing Fixture Font",fontSize:47)),
            ("sizeStyle",.init(text:"Color and alignment",fontName:"Helvetica",fontSize:33.5,colorHex:"#E08030",alignment:.trailing,verticalAlignment:.top,backgroundColorHex:"#205020",padding:11)),
            ("autoWrap",.init(text:String(repeating:"Unicode café 中文 ",count:16),fontSize:48,boxSizing:.auto,wraps:true)),
            ("scaleDown",.init(text:String(repeating:"Measured Unicode café 中文 ",count:32),fontSize:110,boxSizing:.fixed,wraps:true,overflow:.scaleDown)),
            ("ellipsis",.init(text:String(repeating:"Long title ",count:90),fontSize:70,alignment:.center,wraps:false,overflow:.ellipsis))
        ]
        for (name,text) in cases {
            let scene=scene(text);let before=reference(original,scene);let after=render(optimized,scene)
            precondition(before==after,"Exact native visible pixels changed for \(name)")
            precondition(after==render(optimized,scene),"Cache hit changed \(name)")
            receipt[name]=hash(after)
        }
        print("PASS exact native pixels against original for static/Unicode/fallback/size/style/auto-wrap/scaleDown/ellipsis")
        let owned="StreamOwnedCacheFixture-Regular";precondition(!TitleFontFallback.fontExists(owned))
        let fixtures=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
        let a=fixtures.appendingPathComponent("owned-a.ttf");let b=fixtures.appendingPathComponent("owned-b.ttf");var registered:URL?
        defer{if let registered{precondition(CTFontManagerUnregisterFontsForURL(registered as CFURL,.process,nil),"Owned process font cleanup")}}
        precondition(CTFontManagerRegisterFontsForURL(a as CFURL,.process,nil));registered=a
        let baseText=TextSourcePayload(text:"AAAA AAAAA",fontName:owned,fontSize:160)
        let direct=scene(baseText);let child=scene(baseText);let nested=Scene(name:"Nested",layers:[LayerNode(name:"Child",payload:.scene(.init(sceneID:child.id)),transform:.fullscreen)])
        var tickerText=baseText;tickerText.ticker=TickerOverlayConfiguration()
        var commentText=baseText;commentText.text="AA AAAAA AAAAA AAAAA";commentText.fontSize=70;commentText.recordingChatMessageID="owned-message";commentText.commentHeaderUTF16Length=3
        let inputs:[(String,Scene,[SceneID:Scene],Bool)]=[("direct",direct,[:],false),("nested",nested,[child.id:child],false),("transitionNested",nested,[child.id:child],true),("ticker",scene(tickerText),[:],false),("commentLayout",scene(commentText),[:],false)]
        var prior:[String:Data]=[:]
        for(name,s,r,t)in inputs{prior[name]=render(optimized,s,r,transition:t)}
        precondition(CTFontManagerUnregisterFontsForURL(a as CFURL,.process,nil));registered=nil
        precondition(CTFontManagerRegisterFontsForURL(b as CFURL,.process,nil));registered=b
        RunLoop.current.run(until:Date().addingTimeInterval(0.05))
        let fresh=BaselineSceneRenderer()
        for(name,s,r,t)in inputs{
            let after=render(optimized,s,r,transition:t);let expected=reference(fresh,s,r,transition:t)
            precondition(after==expected,"Same-PostScript replacement left stale \(name) resources")
            precondition(after != prior[name],"Replacement font must actually change \(name) pixels")
            receipt["replacement."+name]=hash(after)
        }
        precondition(CTFontManagerUnregisterFontsForURL(b as CFURL,.process,nil));registered=nil
        RunLoop.current.run(until:Date().addingTimeInterval(0.05))
        precondition(render(optimized,direct)==reference(BaselineSceneRenderer(),direct),"Removed font must return to fresh fallback pixels")
        print("PASS actual process-only same-PostScript replacement refreshes title rasters, ticker CTLine, comment layout, static nested bake and renderTransition; unregister refreshes fallback")

        for transition in [false,true] {
            precondition(CTFontManagerRegisterFontsForURL(a as CFURL,.process,nil));registered=a
            let changing=SceneRenderer()
            let first=LayerNode(name:"First old font",payload:.text(baseText),transform:LayerTransform(position:GraphPoint(x:0.1,y:0.1),size:GraphSize(width:0.7,height:0.3),anchor:.topLeft))
            let second=LayerNode(name:"Second new font",payload:.text(baseText),transform:LayerTransform(position:GraphPoint(x:0.1,y:0.6),size:GraphSize(width:0.7,height:0.3),anchor:.topLeft))
            let twoTitles=Scene(name:"Epoch changes between children",layers:[first,second])
            let parent=Scene(name:"Cached nested pair",layers:[LayerNode(name:"Nested pair",payload:.scene(.init(sceneID:twoTitles.id)),transform:.fullscreen)])
            let registry=[twoTitles.id:twoTitles]
            var replaced=false
            let buildsBefore=TitleFontEpochFixture.shared.buildCount
            TitleFontEpochFixture.shared.afterBuild={
                TitleFontEpochFixture.shared.afterBuild=nil
                let generation=TitleRenderFontCache()
                let before=generation.registryGeneration()
                precondition(CTFontManagerUnregisterFontsForURL(a as CFURL,.process,nil));registered=nil
                precondition(CTFontManagerRegisterFontsForURL(b as CFURL,.process,nil));registered=b
                let deadline=Date().addingTimeInterval(3)
                while generation.registryGeneration()==before && Date()<deadline {
                    RunLoop.current.run(until:Date().addingTimeInterval(0.01))
                }
                precondition(generation.registryGeneration() != before,"Fixture must observe registry epoch change before second title")
                replaced=true
            }
            let inFlight=render(changing,parent,registry,transition:transition)
            precondition(replaced,"Replacement must occur during first nested child's font build")
            precondition(TitleFontEpochFixture.shared.buildCount>=buildsBefore+2,"Second same-key title must rebuild in the changed epoch before enclosing bake finishes")
            let expected=reference(BaselineSceneRenderer(),parent,registry,transition:transition)
            let next=render(changing,parent,registry,transition:transition)
            precondition(next==expected,"Mixed nested bake persisted after child advanced generation")
            precondition(inFlight != next,"Controlled in-flight frame must actually contain old-font pixels")
            precondition(render(changing,parent,registry,transition:transition)==expected,"Subsequent nested cache hit must remain fresh")
            receipt[transition ? "midBuild.transitionNested" : "midBuild.nested"]=hash(next)
            precondition(CTFontManagerUnregisterFontsForURL(b as CFURL,.process,nil));registered=nil
        }
        print("PASS actual registry replacement during >=2-title nested build; one mixed in-flight frame allowed, next settled/transition frame and cache hit equal fresh replacement pixels")
        try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("font-pixel-equivalence.json"),options:.atomic)
    }
}

@main struct TitleRenderFontHarness {
    static func main() throws {
        let output=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        try TitleFontPixelRegression.run(output)
    }
}
