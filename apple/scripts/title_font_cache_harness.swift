import CoreText
import Foundation
import StreamCore

final class Epoch: @unchecked Sendable {
    private let lock=NSLock(); private var value: UInt64=0
    func read()->UInt64 { lock.lock();defer{lock.unlock()};return value }
    func advance(){lock.lock();value+=1;lock.unlock()}
}
func ps(_ font: CTFont)->String { CTFontCopyPostScriptName(font) as String }
func awaitCondition(_ body:()->Bool) {
    let until=Date().addingTimeInterval(3)
    while !body() && Date()<until { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
    precondition(body(),"Font change notification must reach cache")
}
@main struct FontCacheHarness {
 static func main() throws {
    let epoch=Epoch();var builds=0
    let cache=TitleRenderFontCache(capacity:3,generation:{epoch.read()},makeFont:{name,size in builds+=1;return TitleFontFallback.makeFont(requested:name,size:size)})
    let first=cache.resolve(requested:nil,size:30);let repeated=cache.resolve(requested:nil,size:30)
    precondition(builds==1 && CFEqual(first.font,repeated.font))
    _=cache.resolve(requested:nil,size:31);_=cache.resolve(requested:"Helvetica",size:30);precondition(builds==3)
    _=cache.resolve(requested:nil,size:32);_=cache.resolve(requested:nil,size:30);precondition(builds==5,"Capacity bound must evict")
    epoch.advance();_=cache.resolve(requested:nil,size:30);precondition(builds==6,"Changed epoch must rebuild")
    let racing=Epoch();var raceBuilds=0
    let raceCache=TitleRenderFontCache(generation:{racing.read()},makeFont:{name,size in
        raceBuilds+=1
        if raceBuilds==1 { let done=DispatchSemaphore(value:0);DispatchQueue.global().async{racing.advance();done.signal()};done.wait() }
        return TitleFontFallback.makeFont(requested:name,size:size)
    })
    let raced=raceCache.resolve(requested:nil,size:30);let refreshed=raceCache.resolve(requested:nil,size:30);_=raceCache.resolve(requested:nil,size:30)
    precondition(raced.generation==0 && refreshed.generation==1 && raceBuilds==2,"Mid-build epoch result must not persist")
    print("PASS bounded capacity, request/size identity and concurrent epoch change")
    let owned="StreamOwnedCacheFixture-Regular"
    precondition(!TitleFontFallback.fontExists(owned),"Owned fixture must not already be registered")
    let processCache=TitleRenderFontCache();let missing=processCache.resolve(requested:owned,size:60)
    precondition(ps(missing.font) != owned)
    let a=URL(fileURLWithPath:CommandLine.arguments[1]);let b=URL(fileURLWithPath:CommandLine.arguments[2]);var registered:URL?
    defer { if let registered { precondition(CTFontManagerUnregisterFontsForURL(registered as CFURL,.process,nil),"Owned process font cleanup") } }
    precondition(CTFontManagerRegisterFontsForURL(a as CFURL,.process,nil));registered=a
    awaitCondition{processCache.registryGeneration() != missing.generation}
    let installed=processCache.resolve(requested:owned,size:60);precondition(ps(installed.font)==owned)
    var glyph:CGGlyph=0;var char:UniChar=65;precondition(CTFontGetGlyphsForCharacters(installed.font,&char,&glyph,1))
    var advance=CGSize.zero;_=CTFontGetAdvancesForGlyphs(installed.font,.horizontal,&glyph,&advance,1);let widthA=advance.width
    precondition(CTFontManagerUnregisterFontsForURL(a as CFURL,.process,nil));registered=nil
    awaitCondition{processCache.registryGeneration() != installed.generation}
    let removed=processCache.resolve(requested:owned,size:60);precondition(ps(removed.font) != owned)
    precondition(CTFontManagerRegisterFontsForURL(b as CFURL,.process,nil));registered=b
    awaitCondition{processCache.registryGeneration() != removed.generation}
    let replacement=processCache.resolve(requested:owned,size:60);precondition(ps(replacement.font)==owned)
    precondition(CTFontGetGlyphsForCharacters(replacement.font,&char,&glyph,1));_=CTFontGetAdvancesForGlyphs(replacement.font,.horizontal,&glyph,&advance,1)
    precondition(advance.width > widthA,"Same PostScript name must resolve replacement glyph metrics")
    let oldGeneration=processCache.registryGeneration()
    NotificationCenter.default.post(name:NSLocale.currentLocaleDidChangeNotification,object:nil)
    precondition(processCache.registryGeneration() != oldGeneration)
    print("PASS actual process font register/unregister/re-register with same PostScript name and changed glyph metrics; locale invalidation; guaranteed owned cleanup")
 }
}
