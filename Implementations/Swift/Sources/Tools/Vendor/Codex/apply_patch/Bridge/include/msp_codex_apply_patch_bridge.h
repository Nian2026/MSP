#ifndef MSP_CODEX_APPLY_PATCH_BRIDGE_H
#define MSP_CODEX_APPLY_PATCH_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t msp_codex_apply_patch_json(
    const uint8_t *input_ptr,
    size_t input_len,
    uint8_t **output_ptr,
    size_t *output_len
);
int32_t msp_codex_apply_patch_stdin_json(uint8_t **output_ptr, size_t *output_len);
void msp_codex_apply_patch_free(uint8_t *ptr, size_t len);

#ifdef __cplusplus
}
#endif

#endif
