#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NativeONNXBridge : NSObject

@property(nonatomic, readonly) NSArray<NSString *> *encoderInputNames;
@property(nonatomic, readonly) NSArray<NSString *> *encoderOutputNames;
@property(nonatomic, readonly) NSArray<NSString *> *decoderInputNames;
@property(nonatomic, readonly) NSArray<NSString *> *decoderOutputNames;
@property(nonatomic, readonly) NSArray<NSNumber *> *decoderState1Shape;
@property(nonatomic, readonly) NSArray<NSNumber *> *decoderState2Shape;

- (nullable instancetype)initWithModelDirectory:(NSURL *)modelDirectory error:(NSError **)error;
- (nullable NSData *)runEncoderWithFeatures:(NSData *)features featureLength:(int64_t)featureLength encodedLength:(int64_t *)encodedLength outputShape:(NSArray<NSNumber *> *_Nullable *_Nullable)outputShape error:(NSError **)error;
- (nullable NSData *)runDecoderWithEncoderFrame:(NSData *)encoderFrame target:(int64_t)target state1:(NSData *)state1 state2:(NSData *)state2 outputState1:(NSData *_Nullable *_Nullable)outputState1 outputState2:(NSData *_Nullable *_Nullable)outputState2 error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
