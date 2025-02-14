//
//  SDSDViewController.m
//  SDWebImageJPEGXLCoder
//
//  Created by dreampiggy on 02/26/2024.
//  Copyright (c) 2024 dreampiggy. All rights reserved.
//

#import "SDViewController.h"
#import <SDWebImageJPEGXLCoder/SDImageJPEGXLCoder.h>
#import <SDWebImage/SDWebImage.h>
#import <libjxl/jxl/encode.h>

@interface SDViewController ()
@property (nonatomic, strong) UIImageView *imageView1;
@property (nonatomic, strong) UIImageView *imageView2;

@end

@implementation SDViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    
    [SDImageCache.sharedImageCache.diskCache removeAllData];
    
    [[SDImageCodersManager sharedManager] addCoder:[SDImageJPEGXLCoder sharedCoder]];
    
    self.imageView1 = [UIImageView new];
    self.imageView1.contentMode = UIViewContentModeScaleAspectFit;
    [self.view addSubview:self.imageView1];
    
    self.imageView2 = [UIImageView new];
    self.imageView2.contentMode = UIViewContentModeScaleAspectFit;
    [self.view addSubview:self.imageView2];
    
    NSURL *staticURL = [NSURL URLWithString:@"https://jpegxl.info/images/dice.jxl"];
    NSURL *animatedURL = [NSURL URLWithString:@"https://jpegxl.info/images/anim-icos.jxl"];
    
    [self.imageView1 sd_setImageWithURL:staticURL placeholderImage:nil options:0 context:nil progress:nil completed:^(UIImage * _Nullable image, NSError * _Nullable error, SDImageCacheType cacheType, NSURL * _Nullable imageURL) {
        if (image) {
            NSLog(@"%@", @"Static JPEG-XL load success");
        }
        // static JXL encoding
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSUInteger maxFileSize = 4096;
            NSData *jxlData = [SDImageJPEGXLCoder.sharedCoder encodedDataWithImage:image format:SDImageFormatJPEGXL options:@{SDImageCoderEncodeMaxFileSize : @(maxFileSize)}];
            if (jxlData) {
                NSLog(@"Static JPEG-XL encode success, bytes: %lu", (unsigned long)jxlData.length);
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIImage *animatedImage = [UIImage sd_imageWithData:jxlData];
                    self.imageView2.image = animatedImage;
                });
            }
        });
    }];
    [self.imageView2 sd_setImageWithURL:animatedURL placeholderImage:nil completed:^(UIImage * _Nullable image, NSError * _Nullable error, SDImageCacheType cacheType, NSURL * _Nullable imageURL) {
        if (image) {
            NSLog(@"%@", @"Animated JPEG-XL load success");
        }
        // animated JXL encoding
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *jxlData = [SDImageJPEGXLCoder.sharedCoder encodedDataWithImage:image format:SDImageFormatJPEGXL options:@{
                SDImageCoderEncodeJXLDistance : @(3.0),
            }];
            if (jxlData) {
                NSLog(@"Animated JPEG-XL encode success, bytes: %lu", (unsigned long)jxlData.length);
            }
        });
    }];
    
    [self testHDREncoding];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    self.imageView1.frame = CGRectMake(0, 0, self.view.bounds.size.width, self.view.bounds.size.height / 2);
    self.imageView2.frame = CGRectMake(0, self.view.bounds.size.height / 2, self.view.bounds.size.width, self.view.bounds.size.height / 2);
}

- (void)testHDREncoding {
    // Test JXL Encode
    NSURL *HDRURL = [NSURL URLWithString:@"https://ncdn.camarts.cn/iso-hdr-demo.jxl"];
    NSURLSessionTask *task = [NSURLSession.sharedSession dataTaskWithURL:HDRURL completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        UIImage *image = [UIImage imageWithData:data];
        [self encodeJXLWithImage:image];
    }];
    [task resume];
}

- (void)encodeJXLWithImage:(UIImage *)image {
    NSCParameterAssert(image);
    NSDictionary *frameSetting = @{
        @(JXL_ENC_FRAME_SETTING_EFFORT) : @(10),
        @(JXL_ENC_FRAME_SETTING_BROTLI_EFFORT) : @(11)
    };
    // fastest encoding speed but largest compressed size, you can adjust options here
    NSData *data = [SDImageJPEGXLCoder.sharedCoder encodedDataWithImage:image format:SDImageFormatJPEGXL options:@{
//        SDImageCoderEncodeCompressionQuality : @0.68,
        SDImageCoderEncodeJXLDistance : @(3.0),
        SDImageCoderEncodeJXLFrameSetting : frameSetting,
    }];
    NSCParameterAssert(data);
    NSString *tempOutputPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"iso-hdr-demo.jxl"];
    [data writeToFile:tempOutputPath atomically:YES];
    NSLog(@"Written encoded JXL to : %@", tempOutputPath);
    
    CIImage *ciimage = [CIImage imageWithData:data];
    NSString *desc = [ciimage description];
    NSLog(@"Re-decoded JXL CIImage description: %@", desc);
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


@end

