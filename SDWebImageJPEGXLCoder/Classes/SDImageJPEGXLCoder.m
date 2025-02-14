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
    // Allows for now, some jxls use 1/1000 tick per seconds, render 50 ticks per-frame.
//    if (duration < 0.1) {
//        // Should we still try to keep broswer behavior to limit 100ms ?
//        // Like GIF/WebP ?
//        return 0.1;
//    }
    return duration;
}

- (nullable CGImageRef)sd_createJXLImageWithDec:(JxlDecoder *)dec info:(JxlBasicInfo)info colorSpace:(CGColorSpaceRef)colorSpace thumbnailSize:(CGSize)thumbnailSize preserveAspectRatio:(BOOL)preserveAspectRatio CF_RETURNS_RETAINED {
    JxlDecoderStatus status;
    
    // bitmap format
    BOOL hasAlpha = info.alpha_bits != 0;
    BOOL premultiplied = info.alpha_premultiplied;
    SDImagePixelFormat pixelFormat = [SDImageCoderHelper preferredPixelFormat:hasAlpha];
    
    // 16 bit or 8 bit, HDR ?
    JxlDataType data_type;
    CGBitmapInfo bitmapInfo = 0;
    size_t alignment = pixelFormat.alignment;
    size_t components = info.num_color_channels + info.num_extra_channels;
    size_t bitsPerComponent = info.bits_per_sample;
    if (info.exponent_bits_per_sample > 0 || info.alpha_exponent_bits > 0) {
        // float HDR
        data_type = bitsPerComponent > 16 ? JXL_TYPE_FLOAT : JXL_TYPE_FLOAT16;
        bitmapInfo |= kCGBitmapFloatComponents;
    } else {
        // uint
        data_type = bitsPerComponent <= 8 ? JXL_TYPE_UINT8 : JXL_TYPE_UINT16;
    }
    
    switch (data_type) {
        case JXL_TYPE_FLOAT:
            bitmapInfo |= kCGBitmapByteOrder32Host;
            break;
        case JXL_TYPE_FLOAT16:
        case JXL_TYPE_UINT16:
            bitmapInfo |= kCGBitmapByteOrder16Host;
            break;
        case JXL_TYPE_UINT8:
            bitmapInfo |= kCGBitmapByteOrderDefault;
            break;
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
        .data_type = data_type,
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
    // Keep EXIF orientation
#if SD_UIKIT || SD_WATCH
    CGImagePropertyOrientation orientation = [SDImageCoderHelper exifOrientationFromImageOrientation:image.imageOrientation];
#else
    CGImagePropertyOrientation orientation = kCGImagePropertyOrientationUp;
#endif
    // Compression distance
    float distance;
    if (options[SDImageCoderEncodeJXLDistance] != nil) {
        // prefer JXL distance
        distance = [options[SDImageCoderEncodeJXLDistance] floatValue];
    } else {
        // convert JPEG quality (0-100) to JXL distance
        double compressionQuality = 1;
        if (options[SDImageCoderEncodeCompressionQuality]) {
            compressionQuality = [options[SDImageCoderEncodeCompressionQuality] doubleValue];
        }
        distance = JxlEncoderDistanceFromQuality(compressionQuality * 100.0);
    }
    // calculate multithread count
    size_t threadCount = [options[SDImageCoderEncodeJXLThreadCount] unsignedIntValue];
    if (threadCount == 0) {
        threadCount = JxlThreadParallelRunnerDefaultNumWorkerThreads();
    }
    
    NSMutableData *output = [NSMutableData data];
    BOOL success = NO;
    
    // finished basic Animated JPEG-XL Encoding support
    // thanks: https://github.com/FFmpeg/FFmpeg/commit/f3c408264554211b7a4c729d5fe482d633bac01a
    BOOL encodeFirstFrame = [options[SDImageCoderEncodeFirstFrameOnly] boolValue];
    BOOL hasAnimation = !encodeFirstFrame && frames.count > 1;
    
    // encoder context (which need be shared by static/animated encoding)
    JxlEncoder* enc = JxlEncoderCreate(NULL);
    if (!enc) {
        return nil;
    }
    JxlEncoderFrameSettings* frame_settings = JxlEncoderFrameSettingsCreate(enc, NULL);
    // setup basic info for whole encoding
    void* runner = NULL;
    if (threadCount > 1) {
        runner = JxlThreadParallelRunnerCreate(NULL, threadCount);
    }
    JxlEncoderStatus jret = SetupEncoderForPrimaryImage(enc, frame_settings, runner, imageRef, orientation, distance, hasAnimation, loopCount, options);
    if (jret != JXL_ENC_SUCCESS) {
        JxlEncoderDestroy(enc);
        JxlThreadParallelRunnerDestroy(runner);
        return nil;
    }
    
    if (!hasAnimation) {
        // for static single jxl
        success = [self sd_encodeFrameWithEnc:enc frameSettings:frame_settings frame:imageRef orientation:orientation duration:0];
        if (!success) {
            JxlEncoderDestroy(enc);
            JxlThreadParallelRunnerDestroy(runner);
            return nil;
        }
        // finish input and ready for output
        JxlEncoderCloseInput(enc);
        /* libjxl support incremental encoding, but we just wait it until finished */
        jret = EncodeWithEncoder(enc, output);
    } else {
        // for animated jxl
        for (size_t i = 0; i < frames.count; i++) {
            SDImageFrame *currentFrame = frames[i];
            UIImage *currentImage = currentFrame.image;
            double duration = currentFrame.duration;
            
            success = [self sd_encodeFrameWithEnc:enc frameSettings:frame_settings frame:currentImage.CGImage orientation:orientation duration:duration];
            // earily break
            if (!success) {
                JxlEncoderDestroy(enc);
                JxlThreadParallelRunnerDestroy(runner);
                return nil;
            }
            // last frame
            if (i == frames.count - 1) {
                // finish input and ready for output
                JxlEncoderCloseInput(enc);
            }
            /* libjxl support incremental encoding, but we just wait it until finished */
            NSMutableData *frameOutput = [[NSMutableData alloc] init];
            jret = EncodeWithEncoder(enc, frameOutput);
            // append the frame output to the final output
            [output appendData:frameOutput];
        }
    }
    
    // destroying the decoder also frees JxlEncoderFrameSettings
//    free(frame_settings);
    JxlEncoderDestroy(enc);
    JxlThreadParallelRunnerDestroy(runner);
    
    if (jret != JXL_ENC_SUCCESS) {
        return nil;
    }
    return output;
}

// see: https://github.com/libjxl/libjxl/blob/main/lib/jxl/roundtrip_test.cc#L165
static JxlEncoderStatus EncodeWithEncoder(JxlEncoder* enc, NSMutableData *compressed) {
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
            return process_result;
        }
    }
    NSCParameterAssert(process_result == JXL_ENC_SUCCESS);
    // Reduce extra bytes
    NSUInteger final_length = (next_out - (uint8_t *)compressed.mutableBytes);
    [compressed setLength:final_length];
    return JXL_ENC_SUCCESS;
}

static JxlEncoderStatus SetupEncoderForPrimaryImage(JxlEncoder *enc, JxlEncoderFrameSettings *frame_settings, void* runner, CGImageRef imageRef, CGImagePropertyOrientation orientation, float distance, BOOL hasAnimation, NSUInteger loopCount, NSDictionary *options) {
    // bitmap info from CGImage
    size_t width = CGImageGetWidth(imageRef);
    size_t height = CGImageGetHeight(imageRef);
    size_t bitsPerComponent = CGImageGetBitsPerComponent(imageRef);
    size_t bitsPerPixel = CGImageGetBitsPerPixel(imageRef);
    size_t components = bitsPerPixel / bitsPerComponent;
    __unused size_t bytesPerRow = CGImageGetBytesPerRow(imageRef);
    CGBitmapInfo bitmapInfo = CGImageGetBitmapInfo(imageRef);
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
    
    /* Parse the extra options */
    NSDictionary *frameSetting = options[SDImageCoderEncodeJXLFrameSetting];
    BOOL loseless = options[SDImageCoderEncodeJXLLoseless] ? [options[SDImageCoderEncodeJXLLoseless] boolValue] : NO;
    int codeStreamLevel = options[SDImageCoderEncodeJXLCodeStreamLevel] ? [options[SDImageCoderEncodeJXLCodeStreamLevel] intValue] : -1;
    
    /* Calculate the basic info only when primary image provided */
    __block JxlEncoderStatus jret = JXL_ENC_SUCCESS;
    JxlBasicInfo info;
    
    /* populate the basic info settings */
    JxlEncoderInitBasicInfo(&info);
    
    // Check animation
    if (hasAnimation) {
        info.have_animation = 1;
        info.animation.have_timecodes = 0;
        info.animation.num_loops = (uint32_t)loopCount;
        // We use 1000 ticks per seconds for now. So this convert is simple
        info.animation.tps_numerator = 1000;
        info.animation.tps_denominator = 1;
    }
    
    /* bitexact lossless requires there to be no XYB transform */
    info.uses_original_profile = (distance == 0.0) || loseless;
    
    info.xsize = (uint32_t)width;
    info.ysize = (uint32_t)height;
    info.num_extra_channels = (components + 1) % 2;
    info.num_color_channels = (uint32_t)components - info.num_extra_channels;
    info.bits_per_sample = (uint32_t)bitsPerComponent;
    info.alpha_bits = (info.num_extra_channels > 0) * info.bits_per_sample;
    // floating point
    if (SD_OPTIONS_CONTAINS(bitmapInfo, kCGBitmapFloatComponents)) {
        info.exponent_bits_per_sample = info.bits_per_sample > 16 ? 8 : 5;
        info.alpha_exponent_bits = info.alpha_bits ? info.exponent_bits_per_sample : 0;
    } else {
        info.exponent_bits_per_sample = 0;
        info.alpha_exponent_bits = 0;
    }
    // EXIF orientation, matched
    info.orientation = (JxlOrientation)orientation;
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
    
    jret = JxlEncoderSetBasicInfo(enc, &info);
    if (jret != JXL_ENC_SUCCESS) {
        return jret;
    }
    
    // ICC Profile
    NSData *iccProfile = (__bridge_transfer NSData *)CGColorSpaceCopyICCProfile(colorSpace);
    jret = JxlEncoderSetICCProfile(enc, iccProfile.bytes, iccProfile.length);
    if (jret != JXL_ENC_SUCCESS) {
        return jret;
    }
    
    /* This needs to be set each time the encoder is reset */
    jret &= JxlEncoderSetFrameDistance(frame_settings, distance);
    /* Set lossless */
    jret &= JxlEncoderSetFrameLossless(frame_settings, loseless ? 1 : 0);
    /* Set code steram level */
    jret = JxlEncoderSetCodestreamLevel(enc, codeStreamLevel);
    if (jret != JXL_ENC_SUCCESS) {
        return jret;
    }
    
    /* Set extra frame setting */
    [frameSetting enumerateKeysAndObjectsUsingBlock:^(NSNumber * _Nonnull key, NSNumber * _Nonnull value, BOOL * _Nonnull stop) {
        JxlEncoderFrameSettingId frame_key = key.unsignedIntValue;
        // check the value is floating point or integer
        if ([[value stringValue] containsString:@"."]) {
            // floating point value
            double frame_value = value.doubleValue;
            jret &= JxlEncoderFrameSettingsSetFloatOption(frame_settings, frame_key, frame_value);
        } else {
            // integer value
            int64_t frame_value = value.integerValue;
            jret &= JxlEncoderFrameSettingsSetOption(frame_settings, frame_key, frame_value);
        }
    }];
    if (jret != JXL_ENC_SUCCESS) {
        return jret;
    }
    
    if (runner) {
        jret = JxlEncoderSetParallelRunner(enc, JxlThreadParallelRunner, runner);
    }
    
    return jret;
}

static vImage_Error ConvertToRGBABuffer(CGImageRef imageRef, vImage_Buffer *dest) {
    // bitmap info from CGImage
    size_t bitsPerComponent = CGImageGetBitsPerComponent(imageRef);
    size_t bitsPerPixel = CGImageGetBitsPerPixel(imageRef);
    CGBitmapInfo bitmapInfo = CGImageGetBitmapInfo(imageRef);
    CGImageAlphaInfo alphaInfo = bitmapInfo & kCGBitmapAlphaInfoMask;
    CGImageByteOrderInfo byteOrderInfo = bitmapInfo & kCGBitmapByteOrderMask;
    BOOL byteOrderNormal = NO;
    switch (byteOrderInfo) {
        case kCGBitmapByteOrderDefault: {
            byteOrderNormal = YES;
        } break;
        case kCGBitmapByteOrder16Little:
        case kCGBitmapByteOrder32Little: {
        } break;
        case kCGBitmapByteOrder16Big:
        case kCGBitmapByteOrder32Big: {
            byteOrderNormal = YES;
        } break;
        default: break;
    }
    // We must prefer the input CGImage's color space, which may contains ICC profile
    CGColorSpaceRef colorSpace = CGImageGetColorSpace(imageRef);
    // We only supports RGB colorspace, filter the un-supported one (like Monochrome, CMYK, etc)
    if (CGColorSpaceGetModel(colorSpace) != kCGColorSpaceModelRGB) {
        // Ignore and convert, we don't know how to encode this colorspace directlly to WebP
        // This may cause little visible difference because of colorpsace conversion
        colorSpace = NULL;
    }
    CGColorRenderingIntent renderingIntent = CGImageGetRenderingIntent(imageRef);
    
    // Begin here vImage <---
    CGImageAlphaInfo destAlphaInfo = alphaInfo;
    if (alphaInfo == kCGImageAlphaNoneSkipLast || alphaInfo == kCGImageAlphaNoneSkipFirst) {
        destAlphaInfo = kCGImageAlphaNoneSkipLast;
    } else if (alphaInfo == kCGImageAlphaLast || alphaInfo == kCGImageAlphaFirst) {
        destAlphaInfo = kCGImageAlphaLast;
    } else if (alphaInfo == kCGImageAlphaPremultipliedLast || alphaInfo == kCGImageAlphaPremultipliedFirst) {
        destAlphaInfo = kCGImageAlphaLast;
    } else {
        destAlphaInfo = alphaInfo;
    }
    CGImageByteOrderInfo destByteOrderInfo = byteOrderInfo;
    if (!byteOrderNormal) {
        // not RGB order, need reverse...
        if (byteOrderInfo == kCGImageByteOrder16Little) {
            destByteOrderInfo = kCGImageByteOrder16Big;
        } else if (byteOrderInfo == kCGImageByteOrder32Little) {
            destByteOrderInfo = kCGImageByteOrder32Big;
        }
    }
    CGBitmapInfo destBitmapInfo = (CGBitmapInfo)destAlphaInfo | (CGBitmapInfo)destByteOrderInfo;
    if (SD_OPTIONS_CONTAINS(bitmapInfo, kCGBitmapFloatComponents)) {
        destBitmapInfo |= kCGBitmapFloatComponents;
    }
    
    vImage_CGImageFormat destFormat = {
        .bitsPerComponent = (uint32_t)bitsPerComponent,
        .bitsPerPixel = (uint32_t)bitsPerPixel,
        .colorSpace = colorSpace,
        .bitmapInfo = destBitmapInfo,
        .renderingIntent = renderingIntent
    };
    // We could not assume that input CGImage's color mode is always RGB888/RGBA8888. Convert all other cases to target color mode using vImage
    // But vImageBuffer_InitWithCGImage will do convert automatically (unless you use `kvImageNoAllocate`), so no need to call `vImageConvert` by ourselves
    vImage_Error error = vImageBuffer_InitWithCGImage(dest, &destFormat, NULL, imageRef, kvImageNoFlags);
    return error;
    // End here vImage --->
}

// Encode single frame (shared by static/animated jxl encoding)
- (BOOL)sd_encodeFrameWithEnc:(JxlEncoder*)enc
                frameSettings:(JxlEncoderFrameSettings *)frame_settings
                        frame:(nullable CGImageRef)imageRef
                  orientation:(CGImagePropertyOrientation)orientation /*useless*/
                     duration:(double)duration
{
    if (!imageRef) {
        return NO;
    }
    
    size_t width = CGImageGetWidth(imageRef);
    size_t height = CGImageGetHeight(imageRef);
    size_t bitsPerComponent = CGImageGetBitsPerComponent(imageRef);
    size_t bitsPerPixel = CGImageGetBitsPerPixel(imageRef);
    size_t components = bitsPerPixel / bitsPerComponent;
    size_t bytesPerRow = CGImageGetBytesPerRow(imageRef);
    CGBitmapInfo bitmapInfo = CGImageGetBitmapInfo(imageRef);
    
    CFDataRef buffer;
    // is HDR or not ?
    if (bitsPerComponent < 16) {
        // TODO: ugly code, libjxl supports RGBA order only, but input CGImage maybe BGRA, ARGB, etc
        // see: encode.h JxlDataType
        // * TODO(lode): support different channel orders if needed (RGB, BGR, ...)
        vImage_Buffer dest;
        vImage_Error error = ConvertToRGBABuffer(imageRef, &dest);
        if (error != kvImageNoError) {
            return NO;
        }
        bytesPerRow = dest.rowBytes;
        size_t length = bytesPerRow * height;
        buffer = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, dest.data, length, kCFAllocatorDefault);
    } else {
        // directlly use the CGImage's buffer, preserve HDR
        CGDataProviderRef provider = CGImageGetDataProvider(imageRef);
        if (!provider) {
            return NO;
        }
        buffer = CGDataProviderCopyData(provider);
        CGDataProviderRelease(provider);
    }
    
    JxlEncoderStatus jret = JXL_ENC_SUCCESS;
    JxlPixelFormat jxl_fmt;
    
    /* Set the current frame pixel format */
    jxl_fmt.num_channels = (uint32_t)components;
    // TODO: we use vImage, so the align should re-calculate
    size_t alignment = bytesPerRow - (width * bitsPerPixel / 8);
    jxl_fmt.align = alignment;
    // default endian (little)
    jxl_fmt.endianness = JXL_NATIVE_ENDIAN;
    // floating point
    if (SD_OPTIONS_CONTAINS(bitmapInfo, kCGBitmapFloatComponents)) {
        jxl_fmt.data_type = bitsPerComponent > 16 ? JXL_TYPE_FLOAT : JXL_TYPE_FLOAT16;
    } else {
        jxl_fmt.data_type = bitsPerComponent <= 8 ? JXL_TYPE_UINT8 : JXL_TYPE_UINT16;
    }

    if (jret != JXL_ENC_SUCCESS) {
        return NO;
    }
    
    /* Set the duration to frame header, animated image only */
    if (duration > 0) {
        JxlFrameHeader frame_header;
        JxlEncoderInitFrameHeader(&frame_header);
        
        // We use 1000 ticks per seconds for now. So this convert is simple
        float tick_duration = duration * 1000 / 1;
        frame_header.duration = (uint32_t)tick_duration;
        jret = JxlEncoderSetFrameHeader(frame_settings, &frame_header);
    }
    if (jret != JXL_ENC_SUCCESS) {
        return NO;
    }
    
    /* Add frame bitmap buffer */
    jret = JxlEncoderAddImageFrame(frame_settings, &jxl_fmt,
                                   CFDataGetBytePtr(buffer),
                                   CFDataGetLength(buffer));
    // free the allocated buffer
    CFRelease(buffer);
    if (jret != JXL_ENC_SUCCESS) {
        return NO;
    }
    
    return YES;
}

@end

#pragma mark - JXL Encode Options
SDImageCoderOption SDImageCoderEncodeJXLDistance = @"encodeJXLDistance";
SDImageCoderOption SDImageCoderEncodeJXLLoseless = @"encodeJXLLoseless";
SDImageCoderOption SDImageCoderEncodeJXLCodeStreamLevel = @"encodeJXLCodeStreamLevel";
SDImageCoderOption SDImageCoderEncodeJXLFrameSetting = @"encodeJXLFrameSetting";
SDImageCoderOption SDImageCoderEncodeJXLThreadCount = @"encodeJXLThreadCount";
