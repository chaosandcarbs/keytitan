#ifndef KEYTITAN_CORE_H
#define KEYTITAN_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum KtnStatus {
  KTN_STATUS_OK = 0,
  KTN_STATUS_NULL_ARGUMENT = 1,
  KTN_STATUS_INVALID_INPUT = 2,
  KTN_STATUS_CRYPTO_ERROR = 3,
  KTN_STATUS_ALLOCATION_ERROR = 4,
  KTN_STATUS_PANIC = 255,
} KtnStatus;

KtnStatus ktn_version(uint8_t **out_ptr, size_t *out_len);

KtnStatus ktn_decrypt_vault(
    const uint8_t *input_ptr,
    size_t input_len,
    const uint8_t *password_ptr,
    size_t password_len,
    uint8_t **out_ptr,
    size_t *out_len);

KtnStatus ktn_encrypt_vault(
    const uint8_t *sqlite_ptr,
    size_t sqlite_len,
    const uint8_t *password_ptr,
    size_t password_len,
    uint8_t **out_ptr,
    size_t *out_len);

KtnStatus ktn_field_encrypt(
    const uint8_t *password_ptr,
    size_t password_len,
    const uint8_t *plaintext_ptr,
    size_t plaintext_len,
    uint8_t **out_ptr,
    size_t *out_len);

KtnStatus ktn_field_decrypt(
    const uint8_t *password_ptr,
    size_t password_len,
    const uint8_t *ciphertext_ptr,
    size_t ciphertext_len,
    uint8_t **out_ptr,
    size_t *out_len);

KtnStatus ktn_derive_uris(
    const uint8_t *site_ptr,
    size_t site_len,
    uint8_t **out_ptr,
    size_t *out_len);

/* Frees buffers returned by keytitan_core. Passing any other pointer is invalid. */
void ktn_free(uint8_t *ptr, size_t len);

#ifdef __cplusplus
}
#endif

#endif
