#ifndef PHOTOSORTER_VISION_OCR_EXCEPTION_GUARD_H
#define PHOTOSORTER_VISION_OCR_EXCEPTION_GUARD_H

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <Vision/Vision.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const PhotoSorterVisionOCRExceptionGuardErrorDomain;

@interface PhotoSorterVisionOCRExceptionGuard : NSObject

+ (nullable NSArray<VNRecognizedTextObservation *> *)performTextRecognitionWithImage:(CGImageRef)image
                                                                         orientation:(CGImagePropertyOrientation)orientation
                                                                               error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(performTextRecognition(image:orientation:));

@end

NS_ASSUME_NONNULL_END

#endif
