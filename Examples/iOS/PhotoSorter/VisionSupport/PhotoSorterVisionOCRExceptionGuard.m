#import "include/PhotoSorterVisionSupport/PhotoSorterVisionOCRExceptionGuard.h"

NSErrorDomain const PhotoSorterVisionOCRExceptionGuardErrorDomain = @"PhotoSorterVisionOCRExceptionGuard";

static NSError *PhotoSorterVisionOCRGuardError(NSInteger code, NSString *description, NSException * _Nullable exception) {
    NSMutableDictionary<NSErrorUserInfoKey, id> *userInfo = [NSMutableDictionary dictionary];
    if (description.length > 0) {
        userInfo[NSLocalizedDescriptionKey] = description;
    }
    if (exception.name.length > 0) {
        userInfo[@"PhotoSorterVisionExceptionName"] = exception.name;
    }
    if (exception.reason.length > 0) {
        userInfo[@"PhotoSorterVisionExceptionReason"] = exception.reason;
    }
    return [NSError errorWithDomain:PhotoSorterVisionOCRExceptionGuardErrorDomain code:code userInfo:userInfo];
}

@implementation PhotoSorterVisionOCRExceptionGuard

+ (nullable NSArray<VNRecognizedTextObservation *> *)performTextRecognitionWithImage:(CGImageRef)image
                                                                         orientation:(CGImagePropertyOrientation)orientation
                                                                               error:(NSError * _Nullable * _Nullable)error {
    if (image == nil) {
        if (error != nil) {
            *error = PhotoSorterVisionOCRGuardError(1, @"Vision OCR received an empty image.", nil);
        }
        return nil;
    }

    @autoreleasepool {
        @try {
            VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
            request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
            request.usesLanguageCorrection = YES;
            if ([request respondsToSelector:@selector(setAutomaticallyDetectsLanguage:)]) {
                request.automaticallyDetectsLanguage = YES;
            }

            VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image
                                                                                orientation:orientation
                                                                                    options:@{}];
            NSError *performError = nil;
            BOOL succeeded = [handler performRequests:@[request] error:&performError];
            if (!succeeded) {
                if (error != nil) {
                    *error = performError ?: PhotoSorterVisionOCRGuardError(
                        2,
                        @"Vision OCR failed without a detailed error.",
                        nil
                    );
                }
                return nil;
            }

            NSArray *results = request.results ?: @[];
            NSMutableArray<VNRecognizedTextObservation *> *observations = [NSMutableArray arrayWithCapacity:results.count];
            for (id result in results) {
                if ([result isKindOfClass:VNRecognizedTextObservation.class]) {
                    [observations addObject:(VNRecognizedTextObservation *)result];
                }
            }
            return [observations copy];
        } @catch (NSException *exception) {
            if (error != nil) {
                NSString *description = exception.reason.length > 0
                    ? [NSString stringWithFormat:@"Vision OCR raised %@: %@", exception.name, exception.reason]
                    : [NSString stringWithFormat:@"Vision OCR raised %@.", exception.name];
                *error = PhotoSorterVisionOCRGuardError(3, description, exception);
            }
            return nil;
        }
    }
}

@end
