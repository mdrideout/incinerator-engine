#ifndef INCINERATOR_NEURAL_RENDERING_MACOS_H
#define INCINERATOR_NEURAL_RENDERING_MACOS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void *incinerator_nr_model_create(
    const char *model_path,
    const uint32_t *semantic_codes,
    size_t semantic_code_count,
    const uint32_t *instance_codes,
    size_t instance_code_count,
    const float *control_minimum,
    const float *control_maximum,
    char *error_text,
    size_t error_capacity);

void incinerator_nr_model_destroy(void *handle);

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
    size_t error_capacity);

#ifdef __cplusplus
}
#endif

#endif
