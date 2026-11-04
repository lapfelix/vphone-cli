#ifndef VPHONE_BOOT_LZFSE_H
#define VPHONE_BOOT_LZFSE_H

#include <stddef.h>
#include <stdint.h>

size_t vphone_boot_lzfse_encode_buffer(uint8_t *destination,
                                       size_t destination_size,
                                       const uint8_t *source,
                                       size_t source_size);

#endif
