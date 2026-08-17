#import "macos.h"

#import <CoreML/CoreML.h>
#import <Foundation/Foundation.h>

#include <math.h>
#include <stdlib.h>
#include <string.h>

@interface IncineratorNeuralModel : NSObject {
@public
    uint32_t *_semanticCodes;
    size_t _semanticCodeCount;
    uint32_t *_instanceCodes;
    size_t _instanceCodeCount;
    float _controlMinimum[5];
    float _controlScale[5];
}
@property(nonatomic, strong) MLModel *model;
@property(nonatomic, strong) NSURL *compiledURL;
@end

@implementation IncineratorNeuralModel
- (void)dealloc {
    free(_semanticCodes);
    free(_instanceCodes);
}
@end

static void write_error(char *destination, size_t capacity, NSString *message) {
    if (destination == NULL || capacity == 0) return;
    const char *utf8 = message != nil ? message.UTF8String : "unknown Core ML error";
    if (utf8 == NULL) utf8 = "Core ML returned non-UTF8 error text";
    snprintf(destination, capacity, "%s", utf8);
}

static bool copy_codes(uint32_t **destination, const uint32_t *source, size_t count) {
    if (source == NULL || count == 0) return false;
    uint32_t *copy = malloc(count * sizeof(uint32_t));
    if (copy == NULL) return false;
    memcpy(copy, source, count * sizeof(uint32_t));
    *destination = copy;
    return true;
}

void *incinerator_nr_model_create(
    const char *model_path,
    const uint32_t *semantic_codes,
    size_t semantic_code_count,
    const uint32_t *instance_codes,
    size_t instance_code_count,
    const float *control_minimum,
    const float *control_maximum,
    char *error_text,
    size_t error_capacity) {
    @autoreleasepool {
        if (model_path == NULL || model_path[0] == '\0' ||
            control_minimum == NULL || control_maximum == NULL) {
            write_error(error_text, error_capacity, @"model creation received an empty argument");
            return NULL;
        }
        NSString *path = [NSString stringWithUTF8String:model_path];
        if (path == nil) {
            write_error(error_text, error_capacity, @"model path is not UTF-8");
            return NULL;
        }
        NSURL *sourceURL = [NSURL fileURLWithPath:path isDirectory:YES];
        NSError *error = nil;
        NSURL *compiledURL = [MLModel compileModelAtURL:sourceURL error:&error];
        if (compiledURL == nil) {
            write_error(error_text, error_capacity, error.localizedDescription);
            return NULL;
        }
        MLModelConfiguration *configuration = [[MLModelConfiguration alloc] init];
        configuration.computeUnits = MLComputeUnitsAll;
        MLModel *model = [MLModel modelWithContentsOfURL:compiledURL
                                          configuration:configuration
                                                  error:&error];
        if (model == nil) {
            [[NSFileManager defaultManager] removeItemAtURL:compiledURL error:nil];
            write_error(error_text, error_capacity, error.localizedDescription);
            return NULL;
        }
        IncineratorNeuralModel *box = [[IncineratorNeuralModel alloc] init];
        box.model = model;
        box.compiledURL = compiledURL;
        if (!copy_codes(&box->_semanticCodes, semantic_codes, semantic_code_count) ||
            !copy_codes(&box->_instanceCodes, instance_codes, instance_code_count)) {
            [[NSFileManager defaultManager] removeItemAtURL:compiledURL error:nil];
            write_error(error_text, error_capacity, @"categorical vocabulary allocation failed");
            return NULL;
        }
        box->_semanticCodeCount = semantic_code_count;
        box->_instanceCodeCount = instance_code_count;
        for (size_t index = 0; index < 5; ++index) {
            box->_controlMinimum[index] = control_minimum[index];
            const float range = control_maximum[index] - control_minimum[index];
            box->_controlScale[index] = range > 0.0f ? range : 1.0f;
        }
        if (error_text != NULL && error_capacity != 0) error_text[0] = '\0';
        return (__bridge_retained void *)box;
    }
}

void incinerator_nr_model_destroy(void *handle) {
    if (handle == NULL) return;
    @autoreleasepool {
        IncineratorNeuralModel *box = (__bridge_transfer IncineratorNeuralModel *)handle;
        if (box.compiledURL != nil) {
            [[NSFileManager defaultManager] removeItemAtURL:box.compiledURL error:nil];
        }
    }
}

static float srgb_to_linear(uint8_t encoded) {
    const float value = (float)encoded / 255.0f;
    return value <= 0.04045f
        ? value / 12.92f
        : powf((value + 0.055f) / 1.055f, 2.4f);
}

static int32_t category_index(
    uint32_t encoded,
    const uint32_t *codes,
    size_t count,
    uint64_t *unknown) {
    for (size_t index = 0; index < count; ++index) {
        if (codes[index] == encoded) return (int32_t)index;
    }
    if (unknown != NULL) *unknown += 1;
    return 0;
}

static uint32_t rgb24(const uint8_t *pixels, size_t offset) {
    return (uint32_t)pixels[offset] |
        ((uint32_t)pixels[offset + 1] << 8) |
        ((uint32_t)pixels[offset + 2] << 16);
}

static bool make_multi_array(
    MLMultiArray **destination,
    NSArray<NSNumber *> *shape,
    MLMultiArrayDataType data_type,
    NSError **error) {
    *destination = [[MLMultiArray alloc] initWithShape:shape dataType:data_type error:error];
    return *destination != nil;
}

static float output_value(MLMultiArray *output, size_t index) {
    if (output.dataType == MLMultiArrayDataTypeFloat32) {
        return ((const float *)output.dataPointer)[index];
    }
    if (output.dataType == MLMultiArrayDataTypeDouble) {
        return (float)((const double *)output.dataPointer)[index];
    }
    return NAN;
}

static uint8_t display_channel(float linear_hdr) {
    if (!isfinite(linear_hdr)) return 0;
    const float positive = fmaxf(linear_hdr, 0.0f);
    const float mapped = positive / (1.0f + positive);
    const float srgb = mapped <= 0.0031308f
        ? mapped * 12.92f
        : 1.055f * powf(mapped, 1.0f / 2.4f) - 0.055f;
    return (uint8_t)lrintf(fminf(fmaxf(srgb, 0.0f), 1.0f) * 255.0f);
}

bool incinerator_nr_model_predict(
    void *handle,
    const uint8_t *appearance_pixels,
    const uint8_t *linear_depth_pixels,
    const uint8_t *world_normal_pixels,
    const uint8_t *motion_pixels,
    const uint8_t *semantic_pixels,
    const uint8_t *instance_pixels,
    uint32_t input_width,
    uint32_t input_height,
    const float *global_controls,
    uint8_t *output_pixels,
    uint32_t output_width,
    uint32_t output_height,
    uint64_t *unknown_semantic_pixels,
    uint64_t *unknown_instance_pixels,
    double *inference_ms,
    char *error_text,
    size_t error_capacity) {
    @autoreleasepool {
        if (handle == NULL || appearance_pixels == NULL || linear_depth_pixels == NULL ||
            world_normal_pixels == NULL || motion_pixels == NULL || semantic_pixels == NULL ||
            instance_pixels == NULL || global_controls == NULL || output_pixels == NULL) {
            write_error(error_text, error_capacity, @"prediction received a null argument");
            return false;
        }
        IncineratorNeuralModel *box = (__bridge IncineratorNeuralModel *)handle;
        NSError *error = nil;
        MLMultiArray *continuous = nil;
        MLMultiArray *semantic = nil;
        MLMultiArray *instance = nil;
        MLMultiArray *controls = nil;
        if (!make_multi_array(&continuous, @[@1, @11, @(input_height), @(input_width)], MLMultiArrayDataTypeFloat32, &error) ||
            !make_multi_array(&semantic, @[@1, @(input_height), @(input_width)], MLMultiArrayDataTypeInt32, &error) ||
            !make_multi_array(&instance, @[@1, @(input_height), @(input_width)], MLMultiArrayDataTypeInt32, &error) ||
            !make_multi_array(&controls, @[@1, @5], MLMultiArrayDataTypeFloat32, &error)) {
            write_error(error_text, error_capacity, error.localizedDescription);
            return false;
        }
        float *continuous_values = (float *)continuous.dataPointer;
        int32_t *semantic_values = (int32_t *)semantic.dataPointer;
        int32_t *instance_values = (int32_t *)instance.dataPointer;
        float *control_values = (float *)controls.dataPointer;
        const size_t plane = (size_t)input_width * input_height;
        uint64_t semantic_unknown = 0;
        uint64_t instance_unknown = 0;
        for (size_t pixel = 0; pixel < plane; ++pixel) {
            const size_t source = pixel * 4;
            continuous_values[pixel] = srgb_to_linear(appearance_pixels[source]);
            continuous_values[plane + pixel] = srgb_to_linear(appearance_pixels[source + 1]);
            continuous_values[2 * plane + pixel] = srgb_to_linear(appearance_pixels[source + 2]);
            continuous_values[3 * plane + pixel] = (float)linear_depth_pixels[source] / 255.0f;
            continuous_values[4 * plane + pixel] = (float)world_normal_pixels[source] / 127.5f - 1.0f;
            continuous_values[5 * plane + pixel] = (float)world_normal_pixels[source + 1] / 127.5f - 1.0f;
            continuous_values[6 * plane + pixel] = (float)world_normal_pixels[source + 2] / 127.5f - 1.0f;
            continuous_values[7 * plane + pixel] = (float)motion_pixels[source] / 127.5f - 1.0f;
            continuous_values[8 * plane + pixel] = (float)motion_pixels[source + 1] / 127.5f - 1.0f;
            continuous_values[9 * plane + pixel] = (float)motion_pixels[source + 2] / 255.0f;
            continuous_values[10 * plane + pixel] = (float)appearance_pixels[source + 3] / 255.0f;
            semantic_values[pixel] = category_index(
                rgb24(semantic_pixels, source),
                box->_semanticCodes,
                box->_semanticCodeCount,
                &semantic_unknown);
            instance_values[pixel] = category_index(
                rgb24(instance_pixels, source),
                box->_instanceCodes,
                box->_instanceCodeCount,
                &instance_unknown);
        }
        for (size_t index = 0; index < 5; ++index) {
            control_values[index] =
                (global_controls[index] - box->_controlMinimum[index]) /
                box->_controlScale[index];
        }
        MLDictionaryFeatureProvider *provider = [[MLDictionaryFeatureProvider alloc]
            initWithDictionary:@{
                @"continuous": [MLFeatureValue featureValueWithMultiArray:continuous],
                @"semantic": [MLFeatureValue featureValueWithMultiArray:semantic],
                @"instance": [MLFeatureValue featureValueWithMultiArray:instance],
                @"global_controls": [MLFeatureValue featureValueWithMultiArray:controls],
            }
            error:&error];
        if (provider == nil) {
            write_error(error_text, error_capacity, error.localizedDescription);
            return false;
        }
        const CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
        id<MLFeatureProvider> prediction = [box.model predictionFromFeatures:provider error:&error];
        const CFAbsoluteTime finished = CFAbsoluteTimeGetCurrent();
        if (inference_ms != NULL) *inference_ms = (finished - started) * 1000.0;
        if (prediction == nil) {
            write_error(error_text, error_capacity, error.localizedDescription);
            return false;
        }
        MLMultiArray *output = [prediction featureValueForName:@"scene_color"].multiArrayValue;
        if (output == nil || output.shape.count != 4 ||
            output.shape[0].unsignedIntegerValue != 1 ||
            output.shape[1].unsignedIntegerValue != 3 ||
            output.shape[2].unsignedIntegerValue != output_height ||
            output.shape[3].unsignedIntegerValue != output_width ||
            (output.dataType != MLMultiArrayDataTypeFloat32 &&
             output.dataType != MLMultiArrayDataTypeDouble)) {
            write_error(error_text, error_capacity, @"scene_color has an unexpected shape or type");
            return false;
        }
        const size_t stride_c = output.strides[1].unsignedIntegerValue;
        const size_t stride_y = output.strides[2].unsignedIntegerValue;
        const size_t stride_x = output.strides[3].unsignedIntegerValue;
        for (uint32_t y = 0; y < output_height; ++y) {
            for (uint32_t x = 0; x < output_width; ++x) {
                const size_t spatial = (size_t)y * stride_y + (size_t)x * stride_x;
                const size_t destination = ((size_t)y * output_width + x) * 4;
                output_pixels[destination] = display_channel(output_value(output, spatial));
                output_pixels[destination + 1] = display_channel(output_value(output, stride_c + spatial));
                output_pixels[destination + 2] = display_channel(output_value(output, 2 * stride_c + spatial));
                output_pixels[destination + 3] = 255;
            }
        }
        if (unknown_semantic_pixels != NULL) *unknown_semantic_pixels = semantic_unknown;
        if (unknown_instance_pixels != NULL) *unknown_instance_pixels = instance_unknown;
        if (error_text != NULL && error_capacity != 0) error_text[0] = '\0';
        return true;
    }
}
