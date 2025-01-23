//
//  SDImageJPEGXLCoder.h
//  SDWebImageHEIFCoder
//
//  Created by lizhuoli on 2018/5/8.
//

#if __has_include(<SDWebImage/SDWebImage.h>)
#import <SDWebImage/SDWebImage.h>
#else
@import SDWebImage;
#endif

// TODO: This ugly int-based type should be replaced with a class (like UTType), in SDWebImage 6.0
static const SDImageFormat SDImageFormatJPEGXL = 17; // JPEG-XL

@interface SDImageJPEGXLCoder : NSObject <SDImageCoder>

@property (nonatomic, class, readonly, nonnull) SDImageJPEGXLCoder *sharedCoder;

@end

#pragma mark - JXL Encode Options

/*
 * Sets the distance level for lossy compression: target max butteraugli
 * distance, lower = higher quality. Range: 0 .. 25.
 * 0.0 = mathematically lossless (however, use @ref JxlEncoderSetFrameLossless
 * instead to use true lossless, as setting distance to 0 alone is not the only
 * requirement). 1.0 = visually lossless. Recommended range: 0.5 .. 3.0. Default
 * value: 1.0.
 * See more in upstream: https://libjxl.readthedocs.io/en/latest/api_encoder.html#_CPPv426JxlEncoderSetFrameDistanceP23JxlEncoderFrameSettingsf
 * A NSNumber value. The default value is nil.
 * @note: When you use both `SDImageCoderEncodeCompressionQuality` and this option, this option will override that one and takes effect.
 */
FOUNDATION_EXPORT _Nonnull SDImageCoderOption SDImageCoderEncodeJXLDistance;

/**
 * Enables lossless encoding.
 * See more in upstream: https://libjxl.readthedocs.io/en/latest/api_encoder.html#_CPPv426JxlEncoderSetFrameLosslessP23JxlEncoderFrameSettings8JXL_BOOL
 * A NSNumber value. The default value is NO.
 */
FOUNDATION_EXPORT _Nonnull SDImageCoderOption SDImageCoderEncodeJXLLoseless;

/**
 * Sets the feature level of the JPEG XL codestream. Valid values are 5 and
 * 10, or -1 (to choose automatically). Using the minimum required level, or
 * level 5 in most cases, is recommended for compatibility with all decoders.
 * See more in upstream: https://libjxl.readthedocs.io/en/latest/api_encoder.html#_CPPv428JxlEncoderSetCodestreamLevelP10JxlEncoderi
 * A NSNumber value. The default value is -1.
 */
FOUNDATION_EXPORT _Nonnull SDImageCoderOption SDImageCoderEncodeJXLCodeStreamLevel;

/* Pass extra underlying libjxl encoding frame setting. The Value is a NSDictionary, which each key-value pair use`JxlEncoderFrameSettingId` (NSNumber) as key, and NSNumber as value.
 * See more in upstream: https://libjxl.readthedocs.io/en/latest/api_encoder.html#_CPPv424JxlEncoderFrameSettingId
 * If you can not impoort the libjxl header, just pass the raw int number as `JxlEncoderFrameSettingId`

 Objc code:
 ~~~
 @{SDImageCoderEncodeJXLFrameSetting: @{@JXL_ENC_FRAME_SETTING_EFFORT: @(11)}
 ~~~
 
 Swift code:
 ~~~
 [.encodeJXLFrameSetting : [JxlEncoderFrameSettingId.JXL_ENC_FRAME_SETTING_EFFORT : 11]
 ~~~
*/
FOUNDATION_EXPORT _Nonnull SDImageCoderOption SDImageCoderEncodeJXLFrameSetting;

/**
 * Set the thread count for multithreading. 0 means using logical CPU core (hw.logicalcpu) to detect threads (like 8 core on M1 Mac/ 4 core on iPhone 16 Pro)
 * @warning If you're encoding huge or multiple JXL image at the same time, set this value to 1 to avoid huge CPU usage.
 * A NSNumber value. Defaults to 0, means logical CPU core count. Set to 1 if you want single-thread encoding.
 */
FOUNDATION_EXPORT _Nonnull SDImageCoderOption SDImageCoderEncodeJXLThreadCount;
