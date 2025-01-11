//
//  SDImageJPEGXLCoder.m
//  SDWebImageHEIFCoder
//
//  Created by lizhuoli on 2018/5/8.
//

#import "SDImageJPEGXLCoder.h"
#import <Accelerate/Accelerate.h>
#if __has_include(<jxl/decode.h>) && __has_include(<jxl/encode.h>)
#import <jxl/decode.h>
#import <jxl/encode.h>
#import <jxl/thread_parallel_runner.h>
#else
@import libjxl;
#endif

#ifndef SD_OPTIONS_CONTAINS
#define SD_OPTIONS_CONTAINS(options, value) (((options) & (value)) == (value))
#endif

typedef void (^sd_cleanupBlock_t)(void);

#if defined(__cplusplus)
extern "C" {
#endif
    void sd_executeCleanupBlock (__strong sd_cleanupBlock_t *block);
#if defined(__cplusplus)
}
#endif

// Should moved to SDWebImage Core
#include <sys/sysctl.h>
static int computeHostNumPhysicalCores() {
  uint32_t count;
  size_t len = sizeof(count);
  sysctlbyname("hw.physicalcpu", &count, &len, NULL, 0);
  if (count < 1) {
    int nm[2];
    nm[0] = CTL_HW;
    nm[1] = HW_AVAILCPU;
    sysctl(nm, 2, &count, &len, NULL, 0);
    if (count < 1)
      return -1;
  }
  return count;
}

static void FreeImageData(void *info, const void *data, size_t size) {
    free((void *)data);
}

@implementation SDImageJPEGXLCoder

+ (instancetype)sharedCoder {
    static SDImageJPEGXLCoder *coder;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coder = [[SDImageJPEGXLCoder alloc] init];
    });
    return coder;
}

#pragma mark - Decode

- (BOOL)canDecodeFromData:(NSData *)data {
    // See: https://en.wikipedia.org/wiki/List_of_file_signatures
    if (!data) {
        return NO;
    }
    
    // Seems libjxl has API to check file signatures :)
    JxlSignature result = JxlSignatureCheck(data.bytes, data.length);
    if (result == JXL_SIG_CODESTREAM || result == JXL_SIG_CONTAINER) {
        return YES;
    }
    
    /**
     if (!data) {
     return NO;
     }
     uint16_t magic2;
     [data getBytes:&magic2 length:2];
     if (magic2 == SD_TWO_CC(0xFF, 0x0A)) {
     // FF 0A
     return YES;
     }
     if (data.length >= 12) {
     // 00 00 00 0C 4A 58 4C 20 0D 0A 87 0A
     uint32_t magic4;
     [data getBytes:&magic4 range:NSMakeRange(0, 4)];
     if (magic4 != SD_FOUR_CC(0x00, 0x00, 0x00, 0x0C)) return NO;
     [data getBytes:&magic4 range:NSMakeRange(4, 8)];
     if (magic4 != SD_FOUR_CC(0x4A, 0x58, 0x4C, 0x20)) return NO;
     [data getBytes:&magic4 range:NSMakeRange(8, 12)];
     if (magic4 != SD_FOUR_CC(0x0D, 0x0A, 0x87, 0x0A)) return NO;
     return YES;
     }
     */
    
    return NO;
}

- (UIImage *)decodedImageWithData:(NSData *)data options:(SDImageCoderOptions *)options {
    if (!data) {
        return nil;
    }
    BOOL decodeFirstFrame = [options[SDImageCoderDecodeFirstFrameOnly] boolValue];
    CGFloat scale = 1;
    if ([options valueForKey:SDImageCoderDecodeScaleFactor]) {
        scale = [[options valueForKey:SDImageCoderDecodeScaleFactor] doubleValue];
        if (scale < 1) {
            scale = 1;
        }
    }
    
    CGSize thumbnailSize = CGSizeZero;
    NSValue *thumbnailSizeValue = options[SDImageCoderDecodeThumbnailPixelSize];
    if (thumbnailSizeValue != nil) {
#if SD_MAC
        thumbnailSize = thumbnailSizeValue.sizeValue;
#else
        thumbnailSize = thumbnailSizeValue.CGSizeValue;
#endif
    }
    
    BOOL preserveAspectRatio = YES;
    NSNumber *preserveAspectRatioValue = options[SDImageCoderDecodePreserveAspectRatio];
    if (preserveAspectRatioValue != nil) {
        preserveAspectRatio = preserveAspectRatioValue.boolValue;
    }
    
    // cleanup
    __block JxlDecoder *dec;
    __block CGColorSpaceRef colorSpaceRef;
    __strong void(^cleanupBlock)(void) __attribute__((cleanup(sd_executeCleanupBlock), unused)) = ^{
        if (colorSpaceRef) {
            CGColorSpaceRelease(colorSpaceRef);
        }
        if (dec) {
            JxlDecoderDestroy(dec);
        }
    };
    
    // Get basic info
    dec = JxlDecoderCreate(NULL);
    if (!dec) return nil;
    
    // feed data
    JxlDecoderStatus status = JxlDecoderSetInput(dec, data.bytes, data.length);
    if (status != JXL_DEC_SUCCESS) return nil;
    
    // note: when using `JxlDecoderSubscribeEvents` libjxl behaves likes incremental decoding
    // which need event loop to get latest status via `JxlDecoderProcessInput`
    // each status reports your next steps's info
    status = JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO | JXL_DEC_COLOR_ENCODING | JXL_DEC_FRAME | JXL_DEC_FULL_IMAGE);
    if (status != JXL_DEC_SUCCESS) return nil;
    
    // decode it
    status = JxlDecoderProcessInput(dec);
    if (status != JXL_DEC_BASIC_INFO) return nil;
    
    // info about size/alpha
    JxlBasicInfo info;
    status = JxlDecoderGetBasicInfo(dec, &info);
    if (status != JXL_DEC_SUCCESS) return nil;
    // By defaults, libjxl applys transform for orientation, unless we call `JxlDecoderSetKeepOrientation`
//    CGImagePropertyOrientation exifOrientation = (CGImagePropertyOrientation)info.orientation;
    
    // colorspace
    size_t profileSize;
    status = JxlDecoderProcessInput(dec);
    if (status != JXL_DEC_COLOR_ENCODING) return nil;
    status = JxlDecoderGetICCProfileSize(dec, JXL_COLOR_PROFILE_TARGET_ORIGINAL, &profileSize);
    
    if (status == JXL_DEC_SUCCESS && profileSize > 0) {
        // embed ICC Profile
        NSMutableData *profileData = [NSMutableData dataWithLength:profileSize];
        status = JxlDecoderGetColorAsICCProfile(dec, JXL_COLOR_PROFILE_TARGET_ORIGINAL, profileData.mutableBytes, profileSize);
        if (status != JXL_DEC_SUCCESS) return nil;
        
        if (@available(iOS 10, tvOS 10, macOS 10.12, watchOS 3, *)) {
            colorSpaceRef = CGColorSpaceCreateWithICCData((__bridge CFDataRef)profileData);
        } else {
            colorSpaceRef = CGColorSpaceCreateWithICCProfile((__bridge CFDataRef)profileData);
        }
    } else {
        // Use deviceRGB
        colorSpaceRef = [SDImageCoderHelper colorSpaceGetDeviceRGB];
        CGColorSpaceRetain(colorSpaceRef);
    }
    
    // animation check
    BOOL hasAnimation = info.have_animation;
    if (!hasAnimation || decodeFirstFrame) {
        status = JxlDecoderProcessInput(dec);
        if (status != JXL_DEC_FRAME) return nil;
        CGImageRef imageRef = [self sd_createJXLImageWithDec:dec info:info colorSpace:colorSpaceRef thumbnailSize:thumbnailSize preserveAspectRatio:preserveAspectRatio];
        if (!imageRef) {
            return nil;
        }
#if SD_MAC
        UIImage *image = [[UIImage alloc] initWithCGImage:imageRef scale:scale orientation:kCGImagePropertyOrientationUp];
#else
        UIImage *image = [[UIImage alloc] initWithCGImage:imageRef scale:scale orientation:UIImageOrientationUp];
#endif
        CGImageRelease(imageRef);
        
        return image;
    }
    // loop frame
    NSUInteger loopCount = info.animation.num_loops;
    NSMutableArray<SDImageFrame *> *frames = [NSMutableArray array];
    JxlFrameHeader header;
    do {
        @autoreleasepool {
            status = JxlDecoderProcessInput(dec);
            if (status != JXL_DEC_FRAME) break;
            status = JxlDecoderGetFrameHeader(dec, &header);
            if (status != JXL_DEC_SUCCESS) continue;
            
            // frame decode
            NSTimeInterval duration = [self sd_frameDurationWithInfo:info header:header];
            CGImageRef imageRef = [self sd_createJXLImageWithDec:dec info:info colorSpace:colorSpaceRef thumbnailSize:thumbnailSize preserveAspectRatio:preserveAspectRatio];
            if (!imageRef) continue;
#if SD_MAC
            UIImage *image = [[UIImage alloc] initWithCGImage:imageRef scale:scale orientation:kCGImagePropertyOrientationUp];
#else
            UIImage *image = [[UIImage alloc] initWithCGImage:imageRef scale:scale orientation:UIImageOrientationUp];
#endif
            CGImageRelease(imageRef);
            
            // Assemble frame
            SDImageFrame *frame = [SDImageFrame frameWithImage:image duration:duration];
            [frames addObject:frame];
        }
    } while (!header.is_last);
    
    UIImage *animatedImage = [SDImageCoderHelper animatedImageWithFrames:frames];
    animatedImage.sd_imageLoopCount = loopCount;
    animatedImage.sd_imageFormat = SDImageFormatJPEGXL;
    
    return animatedImage;
}

- (NSTimeInterval)sd_frameDurationWithInfo:(JxlBasicInfo)info header:(JxlFrameHeader)header {
    // Calculate duration, this is `tick`
    // We need tps (tick per second) to calculate
    NSTimeInterval duration = (double)header.duration * info.animation.tps_denominator / info.animation.tps_numerator;
    if (duration < 0.1) {
        // Should we still try to keep broswer behavior to limit 100ms ?
        // Like GIF/WebP ?
        return 0.1;
    }
    return duration;
}

- (nullable CGImageRef)sd_createJXLImageWithDec:(JxlDecoder *)dec info:(JxlBasicInfo)info colorSpace:(CGColorSpaceRef)colorSpace thumbnailSize:(CGSize)thumbnailSize preserveAspectRatio:(BOOL)preserveAspectRatio CF_RETURNS_RETAINED {
    JxlDecoderStatus status;
    
    // bitmap format
    BOOL hasAlpha = info.alpha_bits != 0;
    BOOL premultiplied = info.alpha_premultiplied;
    SDImagePixelFormat pixelFormat = [SDImageCoderHelper preferredPixelFormat:hasAlpha];
    JxlDataType dataType;
    
    // 16 bit or 8 bit, HDR ?
    CGBitmapInfo bitmapInfo = pixelFormat.bitmapInfo;
    CGImageByteOrderInfo byteOrderInfo = bitmapInfo & kCGBitmapByteOrderMask;
    size_t alignment = pixelFormat.alignment;
    size_t components = hasAlpha ? 4 : 3;
    size_t bitsPerComponent;
    if (bitmapInfo & kCGBitmapFloatComponents) {
        // float16 HDR
        dataType = JXL_TYPE_FLOAT16;
        bitsPerComponent = 16;
        bitmapInfo = kCGBitmapByteOrderDefault | kCGBitmapFloatComponents;
    } else if (byteOrderInfo == kCGBitmapByteOrder16Big || byteOrderInfo == kCGBitmapByteOrder16Little) {
        // uint16 HDR
        dataType = JXL_TYPE_UINT16;
        bitsPerComponent = 16;
        bitmapInfo = kCGBitmapByteOrder16Host;
    } else {
        // uint8 SDR
        dataType = JXL_TYPE_UINT8;
        bitsPerComponent = 8;
        bitmapInfo = kCGBitmapByteOrderDefault;
    }
    // libjxl now always prefer RGB / RGBA order
    if (hasAlpha) {
        if (premultiplied) {
            bitmapInfo |= kCGImageAlphaPremultipliedLast;
        } else {
            bitmapInfo |= kCGImageAlphaLast;
        }
    } else {
        bitmapInfo |= kCGImageAlphaNone;
    }
    JxlPixelFormat format = {
        .num_channels = (uint32_t)components,
        .data_type = dataType,
        .endianness = JXL_NATIVE_ENDIAN,
        .align = alignment
    };
    
    size_t bitsPerPixel = components * bitsPerComponent;
    size_t width = info.xsize;
    size_t height = info.ysize;
    size_t bytesPerRow = SDByteAlign(width * (bitsPerPixel / 8), alignment);
    
    // bitmap buffer
    size_t bufferSize = height * bytesPerRow;
    void *buffer = malloc(bufferSize); // malloc + free
    status = JxlDecoderSetImageOutBuffer(dec, &format, buffer, bufferSize);
    if (status != JXL_DEC_SUCCESS) return nil;
    
    status = JxlDecoderProcessInput(dec);
    if (status != JXL_DEC_FULL_IMAGE) return nil; // Final status
    
    // create CGImage
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, buffer, bufferSize, FreeImageData);
    CGColorRenderingIntent renderingIntent = kCGRenderingIntentDefault;
    BOOL shouldInterpolate = YES;
    CGImageRef originImageRef = CGImageCreate(width, height, bitsPerComponent, bitsPerPixel, bytesPerRow, colorSpace, bitmapInfo, provider, NULL, shouldInterpolate, renderingIntent);
    CGDataProviderRelease(provider);
    
    if (!originImageRef) {
        return nil;
    }
    // TODO: In SDWebImage 6.0 API, coder can choose `whether I supports thumbnail decoding`
    // if return false, we provide a common implementation `after the full image is decoded`
    // do not repeat code in each coder plugin repo :(
    CGSize scaledSize = [SDImageCoderHelper scaledSizeWithImageSize:CGSizeMake(width, height) scaleSize:thumbnailSize preserveAspectRatio:preserveAspectRatio shouldScaleUp:NO];
    CGImageRef imageRef = [SDImageCoderHelper CGImageCreateScaled:originImageRef size:scaledSize];
    CGImageRelease(originImageRef);
    
    return imageRef;
}

#pragma mark - Encode

- (BOOL)canEncodeToFormat:(SDImageFormat)format {
    return format == SDImageFormatJPEGXL;
}


- (NSData *)encodedDataWithImage:(UIImage *)image format:(SDImageFormat)format options:(nullable SDImageCoderOptions *)options {
    if (!image) {
        return nil;
    }
    NSArray<SDImageFrame *> *frames = [SDImageCoderHelper framesFromAnimatedImage:image];
    if (!frames || frames.count == 0) {
        SDImageFrame *frame = [SDImageFrame frameWithImage:image duration:0];
        frames = @[frame];
    }
    return [self encodedDataWithFrames:frames loopCount:image.sd_imageLoopCount format:format options:options];
}

- (NSData *)encodedDataWithFrames:(NSArray<SDImageFrame *> *)frames loopCount:(NSUInteger)loopCount format:(SDImageFormat)format options:(SDImageCoderOptions *)options {
    UIImage *image = frames.firstObject.image; // Primary image
    if (!image) {
        return nil;
    }
    CGImageRef imageRef = image.CGImage;
    if (!imageRef) {
        // Earily return, supports CGImage only
        return nil;
    }
    
    NSData *data;
    
    double compressionQuality = 1;
    if (options[SDImageCoderEncodeCompressionQuality]) {
        compressionQuality = [options[SDImageCoderEncodeCompressionQuality] doubleValue];
    }
    CGSize maxPixelSize = CGSizeZero;
    NSValue *maxPixelSizeValue = options[SDImageCoderEncodeMaxPixelSize];
    if (maxPixelSizeValue != nil) {
#if SD_MAC
        maxPixelSize = maxPixelSizeValue.sizeValue;
#else
        maxPixelSize = maxPixelSizeValue.CGSizeValue;
#endif
    }
    NSUInteger maxFileSize = 0;
    if (options[SDImageCoderEncodeMaxFileSize]) {
        maxFileSize = [options[SDImageCoderEncodeMaxFileSize] unsignedIntegerValue];
    }
    
//    BOOL encodeFirstFrame = [options[SDImageCoderEncodeFirstFrameOnly] boolValue];
//    if (encodeFirstFrame || frames.count <= 1) {
//        
//        // for static single webp image
//        // Keep EXIF orientation
//#if SD_UIKIT || SD_WATCH
//        CGImagePropertyOrientation orientation = [SDImageCoderHelper exifOrientationFromImageOrientation:image.imageOrientation];
//#else
//        CGImagePropertyOrientation orientation = kCGImagePropertyOrientationUp;
//#endif
//        data = [self sd_encodedWebpDataWithImage:imageRef
//                                     orientation:orientation
//                                         quality:compressionQuality
//                                    maxPixelSize:maxPixelSize
//                                     maxFileSize:maxFileSize
//                                         options:options];
//    } else {
//        // for animated webp image
//        WebPMux *mux = WebPMuxNew();
//        if (!mux) {
//            return nil;
//        }
//        for (size_t i = 0; i < frames.count; i++) {
//            SDImageFrame *currentFrame = frames[i];
//            UIImage *currentImage = currentFrame.image;
//            // Keep EXIF orientation
//#if SD_UIKIT || SD_WATCH
//            CGImagePropertyOrientation orientation = [SDImageCoderHelper exifOrientationFromImageOrientation:currentImage.imageOrientation];
//#else
//            CGImagePropertyOrientation orientation = kCGImagePropertyOrientationUp;
//#endif
//            NSData *webpData = [self sd_encodedWebpDataWithImage:currentImage.CGImage
//                                                     orientation:orientation
//                                                         quality:compressionQuality
//                                                    maxPixelSize:maxPixelSize
//                                                     maxFileSize:maxFileSize
//                                                         options:options];
//            int duration = currentFrame.duration * 1000;
//            WebPMuxFrameInfo frame = { .bitstream.bytes = webpData.bytes,
//                .bitstream.size = webpData.length,
//                .duration = duration,
//                .id = WEBP_CHUNK_ANMF,
//                .dispose_method = WEBP_MUX_DISPOSE_BACKGROUND, // each frame will clear canvas
//                .blend_method = WEBP_MUX_NO_BLEND
//            };
//            if (WebPMuxPushFrame(mux, &frame, 0) != WEBP_MUX_OK) {
//                WebPMuxDelete(mux);
//                return nil;
//            }
//        }
//        
//        WebPMuxAnimParams params = { .bgcolor = 0,
//            .loop_count = (int)loopCount
//        };
//        if (WebPMuxSetAnimationParams(mux, &params) != WEBP_MUX_OK) {
//            WebPMuxDelete(mux);
//            return nil;
//        }
//        
//        WebPData outputData;
//        WebPMuxError error = WebPMuxAssemble(mux, &outputData);
//        WebPMuxDelete(mux);
//        if (error != WEBP_MUX_OK) {
//            return nil;
//        }
//        data = [NSData dataWithBytes:outputData.bytes length:outputData.size];
//        WebPDataClear(&outputData);
//    }
    
#if SD_UIKIT || SD_WATCH
    CGImagePropertyOrientation orientation = [SDImageCoderHelper exifOrientationFromImageOrientation:image.imageOrientation];
#else
    CGImagePropertyOrientation orientation = kCGImagePropertyOrientationUp;
#endif
    data = [self sd_encodedJXLDataWithImage:imageRef orientation:orientation quality:compressionQuality maxPixelSize:maxPixelSize maxFileSize:maxFileSize options:nil];
    
    return data;
}

// see: https://github.com/libjxl/libjxl/blob/main/lib/jxl/roundtrip_test.cc#L165
JxlEncoderStatus EncodeWithEncoder(JxlEncoder* enc, NSMutableData *compressed) {
    // increase output buffer by 64 bytes once a time
    [compressed increaseLengthBy:64];
    uint8_t* next_out = compressed.mutableBytes;
    size_t avail_out = compressed.length;
    JxlEncoderStatus process_result = JXL_ENC_NEED_MORE_OUTPUT;
    while (process_result == JXL_ENC_NEED_MORE_OUTPUT) {
        process_result = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
        if (process_result == JXL_ENC_NEED_MORE_OUTPUT) {
            size_t offset = next_out - (uint8_t *)compressed.mutableBytes;
            // allocate more buffer
            [compressed increaseLengthBy:compressed.length *  2];
            next_out = (uint8_t *)compressed.mutableBytes + offset;
            avail_out = compressed.length - offset;
        } else if (process_result == JXL_ENC_ERROR){
            NSLog(@"Failed to encode JXL");
            return process_result;
        }
    }
    NSCParameterAssert(process_result == JXL_ENC_SUCCESS);
    // Reduce extra bytes
    NSUInteger final_length = (next_out - (uint8_t *)compressed.mutableBytes);
    [compressed setLength:final_length];
    return JXL_ENC_SUCCESS;
}

- (nullable NSData *)sd_encodedJXLDataWithImage:(nullable CGImageRef)imageRef
                                     orientation:(CGImagePropertyOrientation)orientation
                                         quality:(double)quality
                                    maxPixelSize:(CGSize)maxPixelSize
                                     maxFileSize:(NSUInteger)maxFileSize
                                         options:(nullable SDImageCoderOptions *)options
{
    if (!imageRef) {
        return nil;
    }
//    // Seems libwebp has no convenient EXIF orientation API ?
//    // Use transform to apply ourselves. Need to release before return
//    // TODO: Use `WebPMuxSetChunk` API to write/read EXIF data, see: https://developers.google.com/speed/webp/docs/riff_container#extended_file_format
//    __block CGImageRef rotatedCGImage = NULL;
//    @onExit {
//        if (rotatedCGImage) {
//            CGImageRelease(rotatedCGImage);
//        }
//    };
//    if (orientation != kCGImagePropertyOrientationUp) {
//        rotatedCGImage = [SDImageCoderHelper CGImageCreateDecoded:imageRef orientation:orientation];
//        NSCParameterAssert(rotatedCGImage);
//        imageRef = rotatedCGImage;
//    }
    
    size_t width = CGImageGetWidth(imageRef);
    size_t height = CGImageGetHeight(imageRef);
    size_t bitsPerComponent = CGImageGetBitsPerComponent(imageRef);
    size_t bitsPerPixel = CGImageGetBitsPerPixel(imageRef);
    size_t components = bitsPerPixel / bitsPerComponent;
    size_t bytesPerRow = CGImageGetBytesPerRow(imageRef);
    CGBitmapInfo bitmapInfo = CGImageGetBitmapInfo(imageRef);
    CGImageAlphaInfo alphaInfo = bitmapInfo & kCGBitmapAlphaInfoMask;
    CGBitmapInfo byteOrderInfo = bitmapInfo & kCGBitmapByteOrderMask;
    BOOL hasAlpha = !(alphaInfo == kCGImageAlphaNone ||
                      alphaInfo == kCGImageAlphaNoneSkipFirst ||
                      alphaInfo == kCGImageAlphaNoneSkipLast);
    BOOL byteOrderNormal = NO;
    switch (byteOrderInfo) {
        case kCGBitmapByteOrderDefault: {
            byteOrderNormal = YES;
        } break;
        case kCGBitmapByteOrder32Little: {
        } break;
        case kCGBitmapByteOrder32Big: {
            byteOrderNormal = YES;
        } break;
        default: break;
    }
    // If we can not get bitmap buffer, early return
    CGDataProviderRef dataProvider = CGImageGetDataProvider(imageRef);
    if (!dataProvider) {
        return nil;
    }
    
    NSData *buffer = (__bridge_transfer NSData *) CGDataProviderCopyData(dataProvider);
    if (!buffer) {
        return nil;
    }
    
    // We must prefer the input CGImage's color space, which may contains ICC profile
    CGColorSpaceRef colorSpace = CGImageGetColorSpace(imageRef);
    // We only supports RGB colorspace, filter the un-supported one (like Monochrome, CMYK, etc)
    if (CGColorSpaceGetModel(colorSpace) != kCGColorSpaceModelRGB) {
        // Ignore and convert, we don't know how to encode this colorspace directlly to WebP
        // This may cause little visible difference because of colorpsace conversion
        colorSpace = NULL;
    }
    if (!colorSpace) {
        colorSpace = [SDImageCoderHelper colorSpaceGetDeviceRGB];
    }
    CGColorRenderingIntent renderingIntent = CGImageGetRenderingIntent(imageRef);
//    uint8_t *rgba = NULL; // RGBA Buffer managed by CFData, don't call `free` on it, instead call `CFRelease` on `dataRef`
//    vImage_CGImageFormat destFormat = {
//        .bitsPerComponent = 8,
//        .bitsPerPixel = hasAlpha ? 32 : 24,
//        .colorSpace = colorSpace,
//        .bitmapInfo = hasAlpha ? kCGImageAlphaLast | kCGBitmapByteOrderDefault : kCGImageAlphaNone | kCGBitmapByteOrderDefault, // RGB888/RGBA8888 (Non-premultiplied to works for libwebp)
//        .renderingIntent = renderingIntent
//    };
//    vImage_Buffer dest;
//    // We could not assume that input CGImage's color mode is always RGB888/RGBA8888. Convert all other cases to target color mode using vImage
//    // But vImageBuffer_InitWithCGImage will do convert automatically (unless you use `kvImageNoAllocate`), so no need to call `vImageConvert` by ourselves
//    vImage_Error error = vImageBuffer_InitWithCGImage(&dest, &destFormat, NULL, imageRef, kvImageNoFlags);
//    if (error != kvImageNoError) {
//        return nil;
//    }
//    rgba = dest.data;
//    bytesPerRow = dest.rowBytes;
    
    JxlBasicInfo info;
    JxlColorEncoding jxl_color;
    JxlPixelFormat jxl_fmt;
    JxlEncoderStatus jret;
    
    // encoder
    JxlEncoder* enc = JxlEncoderCreate(NULL);
    if (!enc) {
        return nil;
    }
    
    /* populate the basic info settings */
    JxlEncoderInitBasicInfo(&info);
    
    jxl_fmt.num_channels = (uint32_t)components;
    info.xsize = (uint32_t)width;
    info.ysize = (uint32_t)height;
    info.num_extra_channels = (jxl_fmt.num_channels + 1) % 2;
    info.num_color_channels = jxl_fmt.num_channels - info.num_extra_channels;
    info.bits_per_sample = bitsPerPixel / jxl_fmt.num_channels;
    info.alpha_bits = (info.num_extra_channels > 0) * info.bits_per_sample;
    // floating point
    if (SD_OPTIONS_CONTAINS(bitmapInfo, kCGBitmapFloatComponents)) {
        info.exponent_bits_per_sample = info.bits_per_sample > 16 ? 8 : 5;
        info.alpha_exponent_bits = info.alpha_bits ? info.exponent_bits_per_sample : 0;
        jxl_fmt.data_type = info.bits_per_sample > 16 ? JXL_TYPE_FLOAT : JXL_TYPE_FLOAT16;
    } else {
        info.exponent_bits_per_sample = 0;
        info.alpha_exponent_bits = 0;
        jxl_fmt.data_type = info.bits_per_sample <= 8 ? JXL_TYPE_UINT8 : JXL_TYPE_UINT16;
    }
    // EXIF orientation, matched
    info.orientation = (JxlOrientation)orientation;
    // default endian (little)
    jxl_fmt.endianness = JXL_NATIVE_ENDIAN;
    // convert JPEG quality (0-100) to JXL distance
    float distance = JxlEncoderDistanceFromQuality(quality * 100.0);
    /* bitexact lossless requires there to be no XYB transform */
    info.uses_original_profile = distance == 0.0;
    /* rendering intent doesn't matter here
     * but libjxl will whine if we don't set it */
    JxlRenderingIntent render_indent;
    switch (renderingIntent) {
        case kCGRenderingIntentDefault:
        case kCGRenderingIntentRelativeColorimetric:
            render_indent = JXL_RENDERING_INTENT_RELATIVE;
            break;
        case kCGRenderingIntentAbsoluteColorimetric:
            render_indent = JXL_RENDERING_INTENT_ABSOLUTE;
            break;
        case kCGRenderingIntentPerceptual:
            render_indent = JXL_RENDERING_INTENT_PERCEPTUAL;
            break;
        case kCGRenderingIntentSaturation:
            render_indent = JXL_RENDERING_INTENT_SATURATION;
            break;
    }
    jxl_color.rendering_intent = render_indent;
    
    // CGImage has its own alignment, since we don't use vImage to re-align the input buffer, don't apply here
    jxl_fmt.align = 0;
    
    jret = JxlEncoderSetBasicInfo(enc, &info);
    if (jret != JXL_ENC_SUCCESS) {
        JxlEncoderDestroy(enc);
        return nil;
    }
    
    jxl_color.color_space = JXL_COLOR_SPACE_RGB;
    // ICC Profile
    NSData *iccProfile = (__bridge_transfer NSData *)CGColorSpaceCopyICCProfile(colorSpace);
    jret = JxlEncoderSetICCProfile(enc, iccProfile.bytes, iccProfile.length);
    if (jret != JXL_ENC_SUCCESS) {
        JxlEncoderDestroy(enc);
        return nil;
    }
    
    /* This needs to be set each time the decoder is reset */
    JxlEncoderFrameSettings* frame_settings = JxlEncoderFrameSettingsCreate(enc, NULL);
    jret = JxlEncoderSetFrameDistance(frame_settings, distance);
//    JxlEncoderSetExtraChannelDistance(frame_settings, distance);
    if (jret != JXL_ENC_SUCCESS) {
        JxlEncoderDestroy(enc);
        return nil;
    }
    
   /* This needs to be set each time the decoder is reset */
    size_t threadCount = computeHostNumPhysicalCores();
    void* runner = JxlThreadParallelRunnerCreate(NULL, threadCount);
    jret = JxlEncoderSetParallelRunner(enc, JxlThreadParallelRunner, runner);
    if (jret != JXL_ENC_SUCCESS) {
        JxlEncoderDestroy(enc);
        return nil;
    }
    
    // Add bitmap buffer
    jret = JxlEncoderAddImageFrame(frame_settings, &jxl_fmt,
                            buffer.bytes,
                            buffer.length);
    if (jret != JXL_ENC_SUCCESS) {
        JxlEncoderDestroy(enc);
        return nil;
    }
    JxlEncoderCloseInput(enc);
    
    // libjxp support incremental encoding, but we just wait it finished
    NSMutableData *output = [NSMutableData data];
    jret = EncodeWithEncoder(enc, output);
    
    /*
     * destroying the decoder also frees JxlEncoderFrameSettings
     */
    JxlEncoderDestroy(enc);
    
    return output;
}

@end
