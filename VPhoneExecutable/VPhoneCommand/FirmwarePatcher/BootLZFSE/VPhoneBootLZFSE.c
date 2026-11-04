#include "VPhoneBootLZFSE.h"
#include "lzfse.h"

size_t vphone_boot_lzfse_encode_buffer(uint8_t *destination,
                                       size_t destination_size,
                                       const uint8_t *source,
                                       size_t source_size) {
  return lzfse_encode_buffer(destination, destination_size, source, source_size,
                             NULL);
}
