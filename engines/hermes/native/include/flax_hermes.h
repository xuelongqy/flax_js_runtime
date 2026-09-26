#ifndef FLAX_HERMES_H
#define FLAX_HERMES_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Returns the FlaxApi table for the requested ABI, or NULL if unsupported.
 * The table has static lifetime. Engine-specific C++ types never cross it. */
__attribute__((visibility("default"))) const void *
flax_hermes_get_api(uint32_t version);

#ifdef __cplusplus
}
#endif
#endif
