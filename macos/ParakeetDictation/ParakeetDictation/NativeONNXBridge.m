#import "NativeONNXBridge.h"

#import <onnxruntime/onnxruntime_c_api.h>

static NSString *const NativeONNXBridgeErrorDomain = @"local.DeskScribe.NativeONNXBridge";

@interface NativeONNXBridge ()
@property(nonatomic) const OrtApi *api;
@property(nonatomic) OrtEnv *env;
@property(nonatomic) OrtSessionOptions *sessionOptions;
@property(nonatomic) OrtSession *encoderSession;
@property(nonatomic) OrtSession *decoderSession;
@property(nonatomic, readwrite) NSArray<NSString *> *encoderInputNames;
@property(nonatomic, readwrite) NSArray<NSString *> *encoderOutputNames;
@property(nonatomic, readwrite) NSArray<NSString *> *decoderInputNames;
@property(nonatomic, readwrite) NSArray<NSString *> *decoderOutputNames;
@property(nonatomic, readwrite) NSArray<NSNumber *> *decoderState1Shape;
@property(nonatomic, readwrite) NSArray<NSNumber *> *decoderState2Shape;
@end

@implementation NativeONNXBridge

- (nullable instancetype)initWithModelDirectory:(NSURL *)modelDirectory error:(NSError **)error {
    self = [super init];
    if (!self) {
        return nil;
    }

    _api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (!_api) {
        [self setError:error message:@"Failed to load ONNX Runtime C API" code:-1];
        return nil;
    }

    if (![self checkStatus:_api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "DeskScribeONNX", &_env) error:error]) {
        return nil;
    }
    if (![self checkStatus:_api->CreateSessionOptions(&_sessionOptions) error:error]) {
        return nil;
    }
    int intraOpThreads = (int)MAX(1, MIN(4, NSProcessInfo.processInfo.activeProcessorCount - 1));
    if (![self checkStatus:_api->SetIntraOpNumThreads(_sessionOptions, intraOpThreads) error:error]) {
        return nil;
    }
    if (![self checkStatus:_api->SetInterOpNumThreads(_sessionOptions, 1) error:error]) {
        return nil;
    }
    if (![self checkStatus:_api->SetSessionExecutionMode(_sessionOptions, ORT_SEQUENTIAL) error:error]) {
        return nil;
    }
    if (![self checkStatus:_api->SetSessionGraphOptimizationLevel(_sessionOptions, ORT_ENABLE_ALL) error:error]) {
        return nil;
    }
    if (![self checkStatus:_api->EnableCpuMemArena(_sessionOptions) error:error]) {
        return nil;
    }
    if (![self checkStatus:_api->EnableMemPattern(_sessionOptions) error:error]) {
        return nil;
    }
    NSLog(@"DeskScribe ONNX session options: intraOpThreads=%d interOpThreads=1 execution=sequential graphOptimization=all cpuArena=enabled memPattern=enabled", intraOpThreads);

    NSURL *encoderURL = [modelDirectory URLByAppendingPathComponent:@"encoder-model.onnx"];
    NSURL *decoderURL = [modelDirectory URLByAppendingPathComponent:@"decoder_joint-model.onnx"];

    if (![self loadSessionAtURL:encoderURL into:&_encoderSession error:error]) {
        return nil;
    }
    if (![self loadSessionAtURL:decoderURL into:&_decoderSession error:error]) {
        return nil;
    }

    _encoderInputNames = [self namesForSession:_encoderSession inputs:YES error:error];
    if (!_encoderInputNames) {
        return nil;
    }
    _encoderOutputNames = [self namesForSession:_encoderSession inputs:NO error:error];
    if (!_encoderOutputNames) {
        return nil;
    }
    _decoderInputNames = [self namesForSession:_decoderSession inputs:YES error:error];
    if (!_decoderInputNames) {
        return nil;
    }
    _decoderOutputNames = [self namesForSession:_decoderSession inputs:NO error:error];
    if (!_decoderOutputNames) {
        return nil;
    }

    _decoderState1Shape = [self shapeForSession:_decoderSession inputName:@"input_states_1" error:error];
    if (!_decoderState1Shape) {
        return nil;
    }
    _decoderState2Shape = [self shapeForSession:_decoderSession inputName:@"input_states_2" error:error];
    if (!_decoderState2Shape) {
        return nil;
    }

    return self;
}

- (nullable NSData *)runEncoderWithFeatures:(NSData *)features featureLength:(int64_t)featureLength encodedLength:(int64_t *)encodedLength outputShape:(NSArray<NSNumber *> *_Nullable *_Nullable)outputShape error:(NSError **)error {
    int64_t lengthValue = featureLength;
    int64_t featureFrameCount = (int64_t)(features.length / (128 * sizeof(float)));
    int64_t featureShape[] = {1, 128, featureFrameCount};
    int64_t lengthShape[] = {1};
    OrtValue *featureTensor = NULL;
    OrtValue *lengthTensor = NULL;
    OrtValue *outputs[2] = {NULL, NULL};
    OrtMemoryInfo *memoryInfo = NULL;

    if (![self checkStatus:_api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memoryInfo) error:error]) {
        return nil;
    }
    BOOL ok = [self checkStatus:_api->CreateTensorWithDataAsOrtValue(memoryInfo, (void *)features.bytes, features.length, featureShape, 3, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &featureTensor) error:error] &&
        [self checkStatus:_api->CreateTensorWithDataAsOrtValue(memoryInfo, &lengthValue, sizeof(lengthValue), lengthShape, 1, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &lengthTensor) error:error];
    _api->ReleaseMemoryInfo(memoryInfo);
    if (!ok) {
        if (featureTensor) { _api->ReleaseValue(featureTensor); }
        if (lengthTensor) { _api->ReleaseValue(lengthTensor); }
        return nil;
    }

    const char *inputNames[] = {"audio_signal", "length"};
    const char *outputNames[] = {"outputs", "encoded_lengths"};
    OrtValue *inputValues[] = {featureTensor, lengthTensor};
    ok = [self checkStatus:_api->Run(_encoderSession, NULL, inputNames, (const OrtValue *const *)inputValues, 2, outputNames, 2, outputs) error:error];
    _api->ReleaseValue(featureTensor);
    _api->ReleaseValue(lengthTensor);
    if (!ok) {
        return nil;
    }

    NSArray<NSNumber *> *shape = [self shapeForTensor:outputs[0] error:error];
    NSData *data = shape ? [self floatDataForTensor:outputs[0] shape:shape error:error] : nil;
    int64_t encodedLengthValue = 0;
    if (data) {
        int64_t *lengths = NULL;
        if ([self checkStatus:_api->GetTensorMutableData(outputs[1], (void **)&lengths) error:error]) {
            encodedLengthValue = lengths[0];
        } else {
            data = nil;
        }
    }
    _api->ReleaseValue(outputs[0]);
    _api->ReleaseValue(outputs[1]);

    if (!data) {
        return nil;
    }
    if (encodedLength) {
        *encodedLength = encodedLengthValue;
    }
    if (outputShape) {
        *outputShape = shape;
    }
    return data;
}

- (nullable NSData *)runDecoderWithEncoderFrame:(NSData *)encoderFrame target:(int64_t)target state1:(NSData *)state1 state2:(NSData *)state2 outputState1:(NSData *_Nullable *_Nullable)outputState1 outputState2:(NSData *_Nullable *_Nullable)outputState2 error:(NSError **)error {
    int64_t encoderDims[] = {1, (int64_t)(encoderFrame.length / sizeof(float)), 1};
    int64_t targetDims[] = {1, 1};
    int64_t targetLengthDims[] = {1};
    int32_t targetValue[] = {(int32_t)target};
    int32_t targetLengthValue[] = {1};
    OrtValue *inputs[5] = {NULL, NULL, NULL, NULL, NULL};
    OrtValue *outputs[3] = {NULL, NULL, NULL};
    OrtMemoryInfo *memoryInfo = NULL;

    if (![self checkStatus:_api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memoryInfo) error:error]) {
        return nil;
    }

    BOOL ok = [self createFloatTensor:&inputs[0] data:encoderFrame shape:@[@1, @(encoderDims[1]), @1] memoryInfo:memoryInfo error:error] &&
        [self checkStatus:_api->CreateTensorWithDataAsOrtValue(memoryInfo, targetValue, sizeof(targetValue), targetDims, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32, &inputs[1]) error:error] &&
        [self checkStatus:_api->CreateTensorWithDataAsOrtValue(memoryInfo, targetLengthValue, sizeof(targetLengthValue), targetLengthDims, 1, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32, &inputs[2]) error:error] &&
        [self createFloatTensor:&inputs[3] data:state1 shape:_decoderState1Shape memoryInfo:memoryInfo error:error] &&
        [self createFloatTensor:&inputs[4] data:state2 shape:_decoderState2Shape memoryInfo:memoryInfo error:error];
    _api->ReleaseMemoryInfo(memoryInfo);
    if (!ok) {
        for (NSInteger index = 0; index < 5; index++) { if (inputs[index]) { _api->ReleaseValue(inputs[index]); } }
        return nil;
    }

    const char *inputNames[] = {"encoder_outputs", "targets", "target_length", "input_states_1", "input_states_2"};
    const char *outputNames[] = {"outputs", "output_states_1", "output_states_2"};
    ok = [self checkStatus:_api->Run(_decoderSession, NULL, inputNames, (const OrtValue *const *)inputs, 5, outputNames, 3, outputs) error:error];
    for (NSInteger index = 0; index < 5; index++) { _api->ReleaseValue(inputs[index]); }
    if (!ok) {
        return nil;
    }

    NSArray<NSNumber *> *logitShape = [self shapeForTensor:outputs[0] error:error];
    NSData *logits = logitShape ? [self floatDataForTensor:outputs[0] shape:logitShape error:error] : nil;
    NSArray<NSNumber *> *state1Shape = [self shapeForTensor:outputs[1] error:error];
    NSData *nextState1 = state1Shape ? [self floatDataForTensor:outputs[1] shape:state1Shape error:error] : nil;
    NSArray<NSNumber *> *state2Shape = [self shapeForTensor:outputs[2] error:error];
    NSData *nextState2 = state2Shape ? [self floatDataForTensor:outputs[2] shape:state2Shape error:error] : nil;
    for (NSInteger index = 0; index < 3; index++) { _api->ReleaseValue(outputs[index]); }

    if (!logits || !nextState1 || !nextState2) {
        return nil;
    }
    if (outputState1) { *outputState1 = nextState1; }
    if (outputState2) { *outputState2 = nextState2; }
    return logits;
}

- (void)dealloc {
    if (_decoderSession) {
        _api->ReleaseSession(_decoderSession);
    }
    if (_encoderSession) {
        _api->ReleaseSession(_encoderSession);
    }
    if (_sessionOptions) {
        _api->ReleaseSessionOptions(_sessionOptions);
    }
    if (_env) {
        _api->ReleaseEnv(_env);
    }
}

- (BOOL)loadSessionAtURL:(NSURL *)url into:(OrtSession **)session error:(NSError **)error {
    const char *path = url.fileSystemRepresentation;
    if (!path) {
        [self setError:error message:[NSString stringWithFormat:@"Invalid model path: %@", url.path] code:-2];
        return NO;
    }
    return [self checkStatus:_api->CreateSession(_env, path, _sessionOptions, session) error:error];
}

- (nullable NSArray<NSString *> *)namesForSession:(OrtSession *)session inputs:(BOOL)inputs error:(NSError **)error {
    size_t count = 0;
    OrtStatus *status = inputs ? _api->SessionGetInputCount(session, &count) : _api->SessionGetOutputCount(session, &count);
    if (![self checkStatus:status error:error]) {
        return nil;
    }

    OrtAllocator *allocator = NULL;
    if (![self checkStatus:_api->GetAllocatorWithDefaultOptions(&allocator) error:error]) {
        return nil;
    }

    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:count];
    for (size_t index = 0; index < count; index++) {
        char *rawName = NULL;
        status = inputs ? _api->SessionGetInputName(session, index, allocator, &rawName) : _api->SessionGetOutputName(session, index, allocator, &rawName);
        if (![self checkStatus:status error:error]) {
            return nil;
        }
        [names addObject:[NSString stringWithUTF8String:rawName ?: ""]];
        allocator->Free(allocator, rawName);
    }
    return names;
}

- (nullable NSArray<NSNumber *> *)shapeForSession:(OrtSession *)session inputName:(NSString *)inputName error:(NSError **)error {
    size_t count = 0;
    if (![self checkStatus:_api->SessionGetInputCount(session, &count) error:error]) {
        return nil;
    }
    OrtAllocator *allocator = NULL;
    if (![self checkStatus:_api->GetAllocatorWithDefaultOptions(&allocator) error:error]) {
        return nil;
    }
    for (size_t index = 0; index < count; index++) {
        char *rawName = NULL;
        if (![self checkStatus:_api->SessionGetInputName(session, index, allocator, &rawName) error:error]) {
            return nil;
        }
        NSString *name = [NSString stringWithUTF8String:rawName ?: ""];
        allocator->Free(allocator, rawName);
        if ([name isEqualToString:inputName]) {
            OrtTypeInfo *typeInfo = NULL;
            if (![self checkStatus:_api->SessionGetInputTypeInfo(session, index, &typeInfo) error:error]) {
                return nil;
            }
            NSArray<NSNumber *> *shape = [self shapeForTypeInfo:typeInfo error:error];
            _api->ReleaseTypeInfo(typeInfo);
            return shape;
        }
    }
    [self setError:error message:[NSString stringWithFormat:@"Missing ONNX input %@", inputName] code:-3];
    return nil;
}

- (nullable NSArray<NSNumber *> *)shapeForTypeInfo:(OrtTypeInfo *)typeInfo error:(NSError **)error {
    const OrtTensorTypeAndShapeInfo *tensorInfo = NULL;
    if (![self checkStatus:_api->CastTypeInfoToTensorInfo(typeInfo, &tensorInfo) error:error]) {
        return nil;
    }
    if (!tensorInfo) {
        [self setError:error message:@"ONNX value is not a tensor" code:-4];
        return nil;
    }
    size_t dimCount = 0;
    if (![self checkStatus:_api->GetDimensionsCount(tensorInfo, &dimCount) error:error]) {
        return nil;
    }
    int64_t dims[dimCount];
    if (![self checkStatus:_api->GetDimensions(tensorInfo, dims, dimCount) error:error]) {
        return nil;
    }
    NSMutableArray<NSNumber *> *shape = [NSMutableArray arrayWithCapacity:dimCount];
    for (size_t index = 0; index < dimCount; index++) {
        if (dims[index] <= 0) {
            [shape addObject:@1];
        } else {
            [shape addObject:@(dims[index])];
        }
    }
    return shape;
}

- (nullable NSArray<NSNumber *> *)shapeForTensor:(OrtValue *)tensor error:(NSError **)error {
    OrtTensorTypeAndShapeInfo *tensorInfo = NULL;
    if (![self checkStatus:_api->GetTensorTypeAndShape(tensor, &tensorInfo) error:error]) {
        return nil;
    }
    size_t dimCount = 0;
    BOOL ok = [self checkStatus:_api->GetDimensionsCount(tensorInfo, &dimCount) error:error];
    int64_t dims[dimCount];
    ok = ok && [self checkStatus:_api->GetDimensions(tensorInfo, dims, dimCount) error:error];
    NSMutableArray<NSNumber *> *shape = [NSMutableArray arrayWithCapacity:dimCount];
    if (ok) {
        for (size_t index = 0; index < dimCount; index++) {
            [shape addObject:@(dims[index])];
        }
    }
    _api->ReleaseTensorTypeAndShapeInfo(tensorInfo);
    return ok ? shape : nil;
}

- (BOOL)createFloatTensor:(OrtValue **)tensor data:(NSData *)data shape:(NSArray<NSNumber *> *)shape memoryInfo:(OrtMemoryInfo *)memoryInfo error:(NSError **)error {
    int64_t dims[shape.count];
    int64_t elementCount = 1;
    for (NSUInteger index = 0; index < shape.count; index++) {
        dims[index] = shape[index].longLongValue;
        elementCount *= dims[index];
    }
    if ((NSUInteger)elementCount * sizeof(float) != data.length) {
        [self setError:error message:@"Tensor data size does not match tensor shape" code:-6];
        return NO;
    }
    return [self checkStatus:_api->CreateTensorWithDataAsOrtValue(memoryInfo, (void *)data.bytes, data.length, dims, shape.count, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, tensor) error:error];
}

- (nullable NSData *)floatDataForTensor:(OrtValue *)tensor shape:(NSArray<NSNumber *> *)shape error:(NSError **)error {
    float *raw = NULL;
    if (![self checkStatus:_api->GetTensorMutableData(tensor, (void **)&raw) error:error]) {
        return nil;
    }
    NSInteger count = 1;
    for (NSNumber *dim in shape) {
        count *= dim.integerValue;
    }
    return [NSData dataWithBytes:raw length:(NSUInteger)count * sizeof(float)];
}

- (BOOL)checkStatus:(OrtStatus *)status error:(NSError **)error {
    if (!status) {
        return YES;
    }

    NSString *message = [NSString stringWithUTF8String:_api->GetErrorMessage(status) ?: "ONNX Runtime error"];
    OrtErrorCode code = _api->GetErrorCode(status);
    _api->ReleaseStatus(status);
    [self setError:error message:message code:code];
    return NO;
}

- (void)setError:(NSError **)error message:(NSString *)message code:(NSInteger)code {
    if (!error) {
        return;
    }
    *error = [NSError errorWithDomain:NativeONNXBridgeErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

@end
