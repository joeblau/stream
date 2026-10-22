#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <CoreImage/CoreImage.h>
#import <CoreGraphics/CoreGraphics.h>

static const size_t W=16,H=16,N=4;
static const uint8_t initialPixel[4]={0x35,0x55,0x75,0xff};
static const uint8_t overwritePixel[4]={0xa5,0x85,0x65,0xff};
static NSDictionary *Attrs(void) { return @{(id)kCVPixelBufferWidthKey:@(W),(id)kCVPixelBufferHeightKey:@(H),(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES}; }
static void Fill(CVPixelBufferRef p,const uint8_t color[4]) {
    NSCAssert(CVPixelBufferLockBaseAddress(p,0)==kCVReturnSuccess,@"owned lock");
    uint8_t *b=CVPixelBufferGetBaseAddress(p); size_t stride=CVPixelBufferGetBytesPerRow(p);
    NSCAssert(b&&stride>=W*4,@"owned raster");
    for(size_t y=0;y<H;y++) for(size_t x=0;x<W;x++) memcpy(b+y*stride+x*4,color,4);
    NSCAssert(CVPixelBufferUnlockBaseAddress(p,0)==kCVReturnSuccess,@"owned unlock");
}
static NSData *ReadPixel(CVPixelBufferRef p) {
    if(!p)return nil;
    if(CVPixelBufferLockBaseAddress(p,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess)return nil;
    NSMutableData *d=[NSMutableData dataWithLength:W*H*4]; uint8_t *dst=d.mutableBytes,*src=CVPixelBufferGetBaseAddress(p);size_t stride=CVPixelBufferGetBytesPerRow(p);
    if(!src||stride<W*4){CVPixelBufferUnlockBaseAddress(p,kCVPixelBufferLock_ReadOnly);return nil;}
    for(size_t y=0;y<H;y++)memcpy(dst+y*W*4,src+y*stride,W*4);
    CVPixelBufferUnlockBaseAddress(p,kCVPixelBufferLock_ReadOnly);return d;
}
static NSData *ReadSurface(IOSurfaceRef s) {
    if(!s)return nil; if(IOSurfaceLock(s,kIOSurfaceLockReadOnly,NULL)!=KERN_SUCCESS)return nil;
    NSMutableData *d=[NSMutableData dataWithLength:W*H*4];uint8_t *dst=d.mutableBytes,*src=IOSurfaceGetBaseAddress(s);size_t stride=IOSurfaceGetBytesPerRow(s);
    if(!src||stride<W*4){IOSurfaceUnlock(s,kIOSurfaceLockReadOnly,NULL);return nil;}
    for(size_t y=0;y<H;y++)memcpy(dst+y*W*4,src+y*stride,W*4);
    IOSurfaceUnlock(s,kIOSurfaceLockReadOnly,NULL);return d;
}
typedef struct {
    NSString *kind;
    CVPixelBufferRef pixel,carrier;
    CMSampleBufferRef sample;
    CMVideoFormatDescriptionRef format;
    IOSurfaceRef surface,useSurface;
    CVMetalTextureCacheRef cache;
    CVMetalTextureRef cvTexture;
    id object;
    CIContext *context;
    CGImageRef cgImage;
    BOOL metadataOnly,unsupported;
    int32_t setupStatus;
    IOSurfaceID sourceIdentity;
} Owner;
static CMVideoFormatDescriptionRef MakeFormat(CVPixelBufferRef p) {
    CMVideoFormatDescriptionRef f=NULL;OSStatus r=CMVideoFormatDescriptionCreateForImageBuffer(NULL,p,&f);NSCAssert(r==noErr&&f,@"owned format");return f;
}
static Owner MakeOwner(NSString *kind,CVPixelBufferRef p) {
    Owner o={0};o.kind=kind;o.sourceIdentity=IOSurfaceGetID(CVPixelBufferGetIOSurface(p));
    IOSurfaceRef s=CVPixelBufferGetIOSurface(p);
    if(!s){o.unsupported=YES;o.setupStatus=kCVReturnError;return o;}
    if([kind isEqual:@"raw-cvpixelbuffer-stripped"]){o.pixel=(CVPixelBufferRef)CFRetain(p);CVBufferRemoveAllAttachments(o.pixel);}
    else if([kind isEqual:@"cmsamplebuffer"]){
        CMVideoFormatDescriptionRef f=MakeFormat(p);CMSampleTimingInfo t={CMTimeMake(1,30),CMTimeMake(10,30),kCMTimeInvalid};
        o.setupStatus=CMSampleBufferCreateReadyWithImageBuffer(NULL,p,f,&t,&o.sample);CFRelease(f);
    }else if([kind isEqual:@"iosurface-retain-only"]||[kind isEqual:@"iosurface-use-count"]){o.surface=(IOSurfaceRef)CFRetain(s);if([kind isEqual:@"iosurface-use-count"]){IOSurfaceIncrementUseCount(s);o.useSurface=s;}}
    else if([kind isEqual:@"rewrapped-cvpixelbuffer"]){o.setupStatus=CVPixelBufferCreateWithIOSurface(NULL,s,(__bridge CFDictionaryRef)Attrs(),&o.pixel);}
    else if([kind isEqual:@"metal-direct"]||[kind isEqual:@"metal-direct-use-count"]||[kind isEqual:@"cvmetaltexture"]){
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();if(!device){o.unsupported=YES;return o;}
        if([kind isEqual:@"cvmetaltexture"]){
            o.setupStatus=CVMetalTextureCacheCreate(NULL,NULL,device,NULL,&o.cache);
            if(o.setupStatus==kCVReturnSuccess)o.setupStatus=CVMetalTextureCacheCreateTextureFromImage(NULL,o.cache,p,NULL,MTLPixelFormatBGRA8Unorm,W,H,0,&o.cvTexture);
        }else{
            MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];d.storageMode=MTLStorageModeShared;
            o.object=[device newTextureWithDescriptor:d iosurface:s plane:0];if(!o.object)o.unsupported=YES;
            if([kind isEqual:@"metal-direct-use-count"]&&o.object){IOSurfaceIncrementUseCount(s);o.useSurface=s;}
        }
        [device release];
    }else if([kind isEqual:@"ciimage"]||[kind isEqual:@"cgimage-deferred"]){
        o.context=[[CIContext alloc]initWithOptions:@{kCIContextUseSoftwareRenderer:@YES,kCIContextWorkingColorSpace:[NSNull null],kCIContextOutputColorSpace:[NSNull null],kCIContextCacheIntermediates:@NO}];
        CIImage *image=[[CIImage alloc]initWithCVPixelBuffer:p];
        if([kind isEqual:@"ciimage"])o.object=image;
        else {CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();o.cgImage=[o.context createCGImage:image fromRect:CGRectMake(0,0,W,H) format:kCIFormatBGRA8 colorSpace:cs deferred:YES];CGColorSpaceRelease(cs);[image release];if(!o.cgImage)o.unsupported=YES;}
    }else if([kind isEqual:@"cmvideoformat-metadata-only"]){o.format=MakeFormat(p);o.metadataOnly=YES;}
    else if([kind isEqual:@"cvattachment-raw-alias"]){
        o.setupStatus=CVPixelBufferCreate(NULL,W,H,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)Attrs(),&o.carrier);
        if(o.carrier)CVBufferSetAttachment(o.carrier,CFSTR("owned.test.alias"),p,kCVAttachmentMode_ShouldNotPropagate);
    }else {NSCAssert(NO,@"unknown owned case");}
    if(o.setupStatus!=0)o.unsupported=YES;return o;
}
static void ReleaseOwner(Owner *o) {
    if(o->useSurface){IOSurfaceDecrementUseCount(o->useSurface);o->useSurface=NULL;}
    if(o->pixel)CFRelease(o->pixel);if(o->carrier)CFRelease(o->carrier);if(o->sample)CFRelease(o->sample);if(o->format)CFRelease(o->format);if(o->surface)CFRelease(o->surface);if(o->cvTexture)CFRelease(o->cvTexture);if(o->cache)CFRelease(o->cache);
    [o->object release];[o->context release];if(o->cgImage)CGImageRelease(o->cgImage);memset(o,0,sizeof(*o));
}
static NSData *ReadOwner(Owner o) {
    if(o.pixel)return ReadPixel(o.pixel);if(o.sample)return ReadPixel(CMSampleBufferGetImageBuffer(o.sample));if(o.surface)return ReadSurface(o.surface);
    if(o.carrier){CFTypeRef v=CVBufferGetAttachment(o.carrier,CFSTR("owned.test.alias"),NULL);return v?ReadPixel((CVPixelBufferRef)v):nil;}
    id<MTLTexture> texture=o.cvTexture?CVMetalTextureGetTexture(o.cvTexture):([o.kind hasPrefix:@"metal-"]?o.object:nil);
    if(texture){NSMutableData *d=[NSMutableData dataWithLength:W*H*4];[texture getBytes:d.mutableBytes bytesPerRow:W*4 fromRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0];return d;}
    if([o.kind isEqual:@"ciimage"]){NSMutableData *d=[NSMutableData dataWithLength:W*H*4];[o.context render:o.object toBitmap:d.mutableBytes rowBytes:W*4 bounds:CGRectMake(0,0,W,H) format:kCIFormatBGRA8 colorSpace:NULL];return d;}
    if(o.cgImage){NSMutableData *d=[NSMutableData dataWithLength:W*H*4];CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();CGContextRef c=CGBitmapContextCreate(d.mutableBytes,W,H,8,W*4,cs,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst);CGColorSpaceRelease(cs);if(!c)return nil;CGContextDrawImage(c,CGRectMake(0,0,W,H),o.cgImage);CGContextRelease(c);return d;}
    return nil;
}
// The reference uses independent unpooled pixels; it never observes/materializes
// the actual held deferred graph before the pool checkout mutation challenge.
static NSData *Reference(NSString *kind) {
    __block NSData *data=nil;
    @autoreleasepool {CVPixelBufferRef p=NULL;NSCAssert(CVPixelBufferCreate(NULL,W,H,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)Attrs(),&p)==0,@"reference pixel");Fill(p,initialPixel);Owner o=MakeOwner(kind,p);CFRelease(p);data=[ReadOwner(o)copy];ReleaseOwner(&o);}
    return [data autorelease];
}
static NSDictionary *Probe(CVPixelBufferPoolRef pool,Owner o,NSData *expected) {
    CVPixelBufferRef held[4]={0};NSMutableArray *statuses=[NSMutableArray array];BOOL same=NO;size_t successes=0;
    for(size_t i=0;i<N;i++){
        CVReturn r=CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(NULL,pool,(__bridge CFDictionaryRef)@{(id)kCVPixelBufferPoolAllocationThresholdKey:@(N)},&held[i]);[statuses addObject:@(r)];
        if(r==0&&held[i]){successes++;IOSurfaceRef s=CVPixelBufferGetIOSurface(held[i]);if(s&&IOSurfaceGetID(s)==o.sourceIdentity)same=YES;Fill(held[i],overwritePixel);}
    }
    NSData *after=ReadOwner(o);BOOL comparable=expected&&after;
    NSDictionary *result=@{@"statuses":statuses,@"simultaneouslyAcquired":@(successes),@"allFourAcquired":@(successes==N),@"acquiredHeldAliasBacking":@(same),@"heldContentComparable":@(comparable),@"heldContentChanged":comparable?@(![expected isEqual:after]):[NSNull null],@"expectedVisibleBytesBase64":expected?[expected base64EncodedStringWithOptions:0]:[NSNull null],@"afterVisibleBytesBase64":after?[after base64EncodedStringWithOptions:0]:[NSNull null]};
    for(size_t i=0;i<N;i++)if(held[i])CFRelease(held[i]);return result;
}
int main(int argc,const char *argv[]){
    @autoreleasepool {
        NSCAssert(argc==2,@"output json path");NSArray *kinds=@[@"raw-cvpixelbuffer-stripped",@"cmsamplebuffer",@"iosurface-retain-only",@"rewrapped-cvpixelbuffer",@"iosurface-use-count",@"metal-direct",@"metal-direct-use-count",@"cvmetaltexture",@"ciimage",@"cgimage-deferred",@"cmvideoformat-metadata-only",@"cvattachment-raw-alias"];
        NSMutableArray *rows=[NSMutableArray array];BOOL genericFalsified=NO,controlsPass=YES;
        for(NSString *kind in kinds){@autoreleasepool {
            CVPixelBufferPoolRef pool=NULL;NSCAssert(CVPixelBufferPoolCreate(NULL,NULL,(__bridge CFDictionaryRef)Attrs(),&pool)==0,@"owned pool");
            NSData *expected=Reference(kind);Owner owner={0};
            @autoreleasepool {CVPixelBufferRef source=NULL;NSCAssert(CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(NULL,pool,(__bridge CFDictionaryRef)@{(id)kCVPixelBufferPoolAllocationThresholdKey:@(N)},&source)==0,@"initial source");Fill(source,initialPixel);owner=MakeOwner(kind,source);CFRelease(source);}
            NSDictionary *beforeRelease=Probe(pool,owner,expected);BOOL unsupported=owner.unsupported,metadataOnly=owner.metadataOnly;int32_t status=owner.setupStatus;
            BOOL falsified=!unsupported&&!metadataOnly&&[beforeRelease[@"allFourAcquired"]boolValue]&&([beforeRelease[@"acquiredHeldAliasBacking"]boolValue]||[beforeRelease[@"heldContentChanged"]boolValue]);genericFalsified|=falsified;
            ReleaseOwner(&owner);
            NSDictionary *afterRelease=Probe(pool,(Owner){0},nil);BOOL control=[afterRelease[@"allFourAcquired"]boolValue];controlsPass&=control;
            NSDictionary *row=@{@"case":kind,@"unsupported":@(unsupported),@"setupStatus":@(status),@"metadataOnly":@(metadataOnly),@"held":beforeRelease,@"afterActualOwnerRelease":afterRelease,@"releaseControlPass":@(control),@"falsifiesGenericRefundOracle":@(falsified)};[rows addObject:row];
            printf("CASE %s acquired=%ld sameBacking=%d contentChanged=%s afterRelease=%ld unsupported=%d\n",kind.UTF8String,(long)[beforeRelease[@"simultaneouslyAcquired"]integerValue],[beforeRelease[@"acquiredHeldAliasBacking"]boolValue],[beforeRelease[@"heldContentChanged"]description].UTF8String,(long)[afterRelease[@"simultaneouslyAcquired"]integerValue],unsupported);
            CFRelease(pool);
        }}
        NSDictionary *result=@{@"scope":@"Owned16x16BGRA IOSurface CVPoolN4 drain-oracle falsification only; fixed4checkouts before+afteractualownerrelease; no capture/media/timing qualification; no literal backingIDs or retaincounts.",@"poolThreshold":@(N),@"dimensions":@[@(W),@(H)],@"genericRefundOracleFalsified":@(genericFalsified),@"allReleaseControlsPassed":@(controlsPass),@"cases":rows};
        NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];NSCAssert([json writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES],@"owned receipt");
        printf("RESULT genericRefundOracleFalsified=%d allReleaseControlsPassed=%d\n",genericFalsified,controlsPass);return controlsPass?0:2;
    }
}
