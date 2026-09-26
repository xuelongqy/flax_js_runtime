#ifndef FLAX_RUNTIME_H
#define FLAX_RUNTIME_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Experimental, process-local ABI. All runtime calls are synchronous. */
#define FLAX_ABI_VERSION 2
#define FLAX_CALLBACK_FAILURE 4

typedef struct FlaxRuntime FlaxRuntime;
typedef uint64_t FlaxValueId;

enum FlaxStatus {
  FLAX_OK = 0,
  FLAX_JS_ERROR = 1,
  FLAX_STATE_ERROR = 2,
  FLAX_ARGUMENT_ERROR = 3,
  FLAX_NATIVE_ERROR = FLAX_CALLBACK_FAILURE
};

enum FlaxValueKind {
  FLAX_UNDEFINED = 0,
  FLAX_NULL = 1,
  FLAX_BOOLEAN = 2,
  FLAX_NUMBER = 3,
  FLAX_STRING = 4,
  FLAX_OBJECT = 5,
  FLAX_FUNCTION = 6
};

/* Zero-initialize before a call. Errors belong to the caller, not the runtime.
 * Release with error_clear, including after a runtime has been destroyed. */
typedef struct FlaxError {
  int32_t code;
  uint8_t *message;
  size_t message_length;
  uint8_t *stack;
  size_t stack_length;
} FlaxError;

/* String values and property names use UTF-16 code units, including unpaired
 * surrogates. Source text, source URLs, and errors use UTF-8 bytes.
 * inspect allocates string_data; free it with buffer_free. */
typedef struct FlaxValueInfo {
  int32_t kind;
  double number;
  uint16_t *string_data;
  size_t string_length;
} FlaxValueInfo;

/* Arguments and this_value are borrowed for this callback only. Use clone_value
 * to retain them. A successful result transfers one value ID to the native
 * host. Errors must be initialized with error_set, never a foreign allocator.
 */
typedef int32_t (*FlaxHostCallback)(void *context, FlaxRuntime *runtime,
                                    FlaxValueId this_value,
                                    const FlaxValueId *arguments, size_t count,
                                    FlaxValueId *result, FlaxError *error);

/* Each successful value-producing call transfers one owned ID to the caller.
 * IDs are valid only in their runtime and until release_value or destroy.
 * Zero denotes undefined only for call's this_value argument.
 * Runtime pointers must not be used after a successful destroy.
 * All calls must originate in the owning Dart isolate's active FFI stack when
 * Dart callbacks are installed. Parallel access is rejected; nested access on
 * the current stack is supported. There are no native background callbacks. */
typedef struct FlaxApi {
  uint32_t version;
  size_t struct_size;
  int32_t (*create)(FlaxRuntime **runtime, FlaxError *error);
  int32_t (*destroy)(FlaxRuntime *runtime, FlaxError *error);
  int32_t (*evaluate)(FlaxRuntime *runtime, const uint8_t *source,
                      size_t source_length, const uint8_t *source_url,
                      size_t source_url_length, FlaxValueId *result,
                      FlaxError *error);
  int32_t (*global_object)(FlaxRuntime *runtime, FlaxValueId *result,
                           FlaxError *error);
  int32_t (*make_value)(FlaxRuntime *runtime, int32_t kind, double number,
                        const uint16_t *string_data, size_t string_length,
                        FlaxValueId *result, FlaxError *error);
  int32_t (*inspect)(FlaxRuntime *runtime, FlaxValueId value,
                     FlaxValueInfo *info, FlaxError *error);
  int32_t (*clone_value)(FlaxRuntime *runtime, FlaxValueId value,
                         FlaxValueId *result, FlaxError *error);
  int32_t (*release_value)(FlaxRuntime *runtime, FlaxValueId value,
                           FlaxError *error);
  int32_t (*get_property)(FlaxRuntime *runtime, FlaxValueId object,
                          const uint16_t *name, size_t name_length,
                          FlaxValueId *result, FlaxError *error);
  int32_t (*set_property)(FlaxRuntime *runtime, FlaxValueId object,
                          const uint16_t *name, size_t name_length,
                          FlaxValueId value, FlaxError *error);
  int32_t (*call)(FlaxRuntime *runtime, FlaxValueId function,
                  FlaxValueId this_value, const FlaxValueId *arguments,
                  size_t count, FlaxValueId *result, FlaxError *error);
  int32_t (*strict_equals)(FlaxRuntime *runtime, FlaxValueId left,
                           FlaxValueId right, int32_t *result,
                           FlaxError *error);
  int32_t (*register_host)(FlaxRuntime *runtime, const uint16_t *name,
                           size_t name_length, FlaxHostCallback callback,
                           void *context, FlaxError *error);
  int32_t (*drain_microtasks)(FlaxRuntime *runtime, int32_t hint,
                              int32_t *complete, FlaxError *error);
  /* Copies bytes into a new ArrayBuffer. read_bytes accepts ArrayBuffer or an
   * actual TypedArray/DataView and copies only its viewed range. Free the result
   * with buffer_free. Detached and shared buffers are rejected. */
  int32_t (*make_bytes)(FlaxRuntime *runtime, const uint8_t *data, size_t length,
                       FlaxValueId *result, FlaxError *error);
  int32_t (*read_bytes)(FlaxRuntime *runtime, FlaxValueId value, uint8_t **data,
                       size_t *length, FlaxError *error);
  void (*buffer_free)(void *buffer);
  void (*error_clear)(FlaxError *error);
  void (*error_set)(FlaxError *error, int32_t code, const uint8_t *message,
                    size_t message_length, const uint8_t *stack,
                    size_t stack_length);
} FlaxApi;

#ifdef __cplusplus
}
#endif
#endif
