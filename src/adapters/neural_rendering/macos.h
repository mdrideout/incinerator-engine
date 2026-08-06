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
    char *error_text,
    size_t error_capacity);

void incinerator_nr_model_destroy(void *handle);

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
    size_t error_capacity);

#ifdef __cplusplus
}
#endif

#endif
