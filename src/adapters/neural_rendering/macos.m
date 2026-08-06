#import "macos.h"

#import <CoreML/CoreML.h>
#import <Foundation/Foundation.h>

#include <math.h>
#include <stdlib.h>
#include <string.h>

@interface IncineratorNeuralModel : NSObject
@property(nonatomic, strong) MLModel *model;
@property(nonatomic, strong) NSURL *compiledURL;
@end

@implementation IncineratorNeuralModel
@end

static void write_error(char *destination, size_t capacity, NSString *message) {
    if (destination == NULL || capacity == 0) return;
    const char *utf8 = message != nil ? message.UTF8String : "unknown Core ML error";
    if (utf8 == NULL) utf8 = "Core ML returned non-UTF8 error text";
    snprintf(destination, capacity, "%s", utf8);
}

static uint16_t float_to_half(float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    const uint32_t sign = (bits >> 16) & 0x8000u;
    int32_t exponent = (int32_t)((bits >> 23) & 0xffu) - 127 + 15;
    uint32_t mantissa = bits & 0x7fffffu;
    if (exponent <= 0) {
        if (exponent < -10) return (uint16_t)sign;
        mantissa = (mantissa | 0x800000u) >> (uint32_t)(1 - exponent);
        return (uint16_t)(sign | ((mantissa + 0x1000u) >> 13));
    }
    if (exponent >= 31) {
        return (uint16_t)(sign | 0x7c00u | (mantissa != 0 ? 0x0200u : 0));
    }
    return (uint16_t)(sign | ((uint32_t)exponent << 10) |
                      ((mantissa + 0x1000u) >> 13));
}

static float half_to_float(uint16_t value) {
    const uint32_t sign = ((uint32_t)value & 0x8000u) << 16;
    uint32_t exponent = ((uint32_t)value >> 10) & 0x1fu;
    uint32_t mantissa = (uint32_t)value & 0x03ffu;
    uint32_t bits;
    if (exponent == 0) {
        if (mantissa == 0) {
            bits = sign;
        } else {
            int32_t adjusted = -14;
            while ((mantissa & 0x0400u) == 0) {
                mantissa <<= 1;
                adjusted -= 1;
            }
            mantissa &= 0x03ffu;
            bits = sign | ((uint32_t)(adjusted + 127) << 23) | (mantissa << 13);
        }
    } else if (exponent == 31) {
        bits = sign | 0x7f800000u | (mantissa << 13);
    } else {
        bits = sign | ((exponent - 15 + 127) << 23) | (mantissa << 13);
    }
    float result;
    memcpy(&result, &bits, sizeof(result));
    return result;
}

void *incinerator_nr_model_create(
    const char *model_path,
    char *error_text,
    size_t error_capacity) {
    @autoreleasepool {
        if (model_path == NULL || model_path[0] == '\0') {
            write_error(error_text, error_capacity, @"model path is empty");
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

bool incinerator_nr_model_predict(
    void *handle,
    const uint8_t *input_pixels,
    uint32_t input_width,
    uint32_t input_height,
    bool input_bgra,
    uint8_t *output_pixels,
    uint32_t output_width,
    uint32_t output_height,
    bool output_bgra,
    double *inference_ms,
    char *error_text,
    size_t error_capacity) {
    @autoreleasepool {
        if (handle == NULL || input_pixels == NULL || output_pixels == NULL) {
            write_error(error_text, error_capacity, @"prediction received a null argument");
            return false;
        }
        IncineratorNeuralModel *box = (__bridge IncineratorNeuralModel *)handle;
        NSError *error = nil;
        MLMultiArray *input = [[MLMultiArray alloc]
            initWithShape:@[@1, @3, @(input_height), @(input_width)]
            dataType:MLMultiArrayDataTypeFloat16
            error:&error];
        if (input == nil) {
            write_error(error_text, error_capacity, error.localizedDescription);
            return false;
        }
        uint16_t *input_values = (uint16_t *)input.dataPointer;
        const size_t plane = (size_t)input_width * input_height;
        for (size_t pixel = 0; pixel < plane; ++pixel) {
            const size_t source = pixel * 4;
            const uint8_t red = input_pixels[source + (input_bgra ? 2 : 0)];
            const uint8_t green = input_pixels[source + 1];
            const uint8_t blue = input_pixels[source + (input_bgra ? 0 : 2)];
            input_values[pixel] = float_to_half((float)red / 255.0f);
            input_values[plane + pixel] = float_to_half((float)green / 255.0f);
            input_values[2 * plane + pixel] = float_to_half((float)blue / 255.0f);
        }
        MLDictionaryFeatureProvider *provider = [[MLDictionaryFeatureProvider alloc]
            initWithDictionary:@{@"low_resolution": [MLFeatureValue featureValueWithMultiArray:input]}
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
            output.shape[3].unsignedIntegerValue != output_width) {
            write_error(error_text, error_capacity, @"scene_color has an unexpected shape");
            return false;
        }
        const size_t stride_c = output.strides[1].unsignedIntegerValue;
        const size_t stride_y = output.strides[2].unsignedIntegerValue;
        const size_t stride_x = output.strides[3].unsignedIntegerValue;
        const uint16_t *half_values = output.dataType == MLMultiArrayDataTypeFloat16
            ? (const uint16_t *)output.dataPointer : NULL;
        const float *float_values = output.dataType == MLMultiArrayDataTypeFloat32
            ? (const float *)output.dataPointer : NULL;
        if (half_values == NULL && float_values == NULL) {
            write_error(error_text, error_capacity, @"scene_color is not float16 or float32");
            return false;
        }
        for (uint32_t y = 0; y < output_height; ++y) {
            for (uint32_t x = 0; x < output_width; ++x) {
                const size_t spatial = (size_t)y * stride_y + (size_t)x * stride_x;
                float channels[3];
                for (size_t channel = 0; channel < 3; ++channel) {
                    const size_t index = channel * stride_c + spatial;
                    channels[channel] = half_values != NULL
                        ? half_to_float(half_values[index]) : float_values[index];
                    channels[channel] = fminf(fmaxf(channels[channel], 0.0f), 1.0f);
                }
                const size_t destination = ((size_t)y * output_width + x) * 4;
                output_pixels[destination + (output_bgra ? 2 : 0)] =
                    (uint8_t)lrintf(channels[0] * 255.0f);
                output_pixels[destination + 1] =
                    (uint8_t)lrintf(channels[1] * 255.0f);
                output_pixels[destination + (output_bgra ? 0 : 2)] =
                    (uint8_t)lrintf(channels[2] * 255.0f);
                output_pixels[destination + 3] = 255;
            }
        }
        if (error_text != NULL && error_capacity != 0) error_text[0] = '\0';
        return true;
    }
}
