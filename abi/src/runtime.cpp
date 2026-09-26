#include "engine.h"

#include "value_id.h"
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

namespace jsi = facebook::jsi;

struct FlaxRuntime {
  std::recursive_mutex mutex;
  size_t depth = 0;
  bool disposing = false;
  std::unique_ptr<jsi::Runtime> js;
  // Declared after js so references are released before the engine.
  std::unique_ptr<jsi::Function> byteView;
  std::unique_ptr<jsi::Function> arrayBufferConstructor;
  std::unordered_map<FlaxValueId, jsi::Value> values;
};

namespace {
flax::ValueIdAllocator<FLAX_ENGINE_ID> nextValue;

struct BridgeError : std::runtime_error {
  int32_t code;
  BridgeError(int32_t code, const char *message)
      : std::runtime_error(message), code(code) {}
};

void clearError(FlaxError *error) noexcept {
  if (!error)
    return;
  std::free(error->message);
  std::free(error->stack);
  *error = {};
}

uint8_t *copyBytes(const uint8_t *data, size_t length) noexcept {
  if (!length)
    return nullptr;
  if (!data)
    return nullptr;
  auto *result = static_cast<uint8_t *>(std::malloc(length));
  if (result)
    std::memcpy(result, data, length);
  return result;
}

void setError(FlaxError *error, int32_t code, const uint8_t *message,
              size_t messageLength, const uint8_t *stack,
              size_t stackLength) noexcept {
  if (!error)
    return;
  clearError(error);
  error->code = code;
  error->message = copyBytes(message, messageLength);
  error->message_length = error->message ? messageLength : 0;
  error->stack = copyBytes(stack, stackLength);
  error->stack_length = error->stack ? stackLength : 0;
}

int32_t fail(FlaxError *error, int32_t code, const std::string &message,
             const std::string &stack = {}) noexcept {
  setError(error, code, reinterpret_cast<const uint8_t *>(message.data()),
           message.size(), reinterpret_cast<const uint8_t *>(stack.data()),
           stack.size());
  return code;
}

template <typename Action>
int32_t protect(FlaxError *error, Action action) noexcept {
  clearError(error);
  try {
    action();
    return FLAX_OK;
  } catch (const jsi::JSError &e) {
    return fail(error, FLAX_JS_ERROR, e.getMessage(), e.getStack());
  } catch (const jsi::JSIException &e) {
    return fail(error, FLAX_JS_ERROR, e.what());
  } catch (const BridgeError &e) {
    return fail(error, e.code, e.what());
  } catch (const std::exception &e) {
    return fail(error, FLAX_NATIVE_ERROR, e.what());
  } catch (...) {
    return fail(error, FLAX_NATIVE_ERROR, "Unknown native exception");
  }
}

struct Entry {
  FlaxRuntime &runtime;
  std::unique_lock<std::recursive_mutex> lock;
  explicit Entry(FlaxRuntime *runtime)
      : runtime(*runtime), lock(runtime->mutex, std::try_to_lock) {
    if (!lock.owns_lock()) {
      throw BridgeError(FLAX_STATE_ERROR, "Concurrent runtime access");
    }
    if (runtime->disposing) {
      throw BridgeError(FLAX_STATE_ERROR, "Runtime is disposing");
    }
    ++runtime->depth;
  }
  ~Entry() { --runtime.depth; }
};

template <typename Action>
int32_t enter(FlaxRuntime *runtime, FlaxError *error, Action action) noexcept {
  return protect(error, [&] {
    if (!runtime)
      throw BridgeError(FLAX_STATE_ERROR, "Null runtime");
    Entry entry(runtime);
    action();
  });
}

std::string text(const uint8_t *data, size_t length) {
  if (!length)
    return {};
  if (!data)
    throw BridgeError(FLAX_ARGUMENT_ERROR, "Null string buffer");
  return {reinterpret_cast<const char *>(data), length};
}

jsi::Value &value(FlaxRuntime *runtime, FlaxValueId id) {
  auto found = runtime->values.find(id);
  if (found == runtime->values.end()) {
    throw BridgeError(FLAX_STATE_ERROR,
                      "Released value or foreign runtime value");
  }
  return found->second;
}

FlaxValueId keep(FlaxRuntime *runtime, jsi::Value value) {
  const auto id = nextValue.next();
  runtime->values.emplace(id, std::move(value));
  return id;
}

jsi::Object object(FlaxRuntime *runtime, FlaxValueId id) {
  auto &v = value(runtime, id);
  if (!v.isObject())
    throw BridgeError(FLAX_ARGUMENT_ERROR, "Expected an object");
  return v.getObject(*runtime->js);
}

std::u16string utf16(const uint16_t *data, size_t length) {
  if (!length)
    return {};
  if (!data)
    throw BridgeError(FLAX_ARGUMENT_ERROR, "Null UTF-16 buffer");
  return {data, data + length};
}

jsi::PropNameID propertyName(FlaxRuntime *runtime, const uint16_t *name,
                             size_t length) {
  return jsi::PropNameID::forUtf16(*runtime->js, utf16(name, length));
}

int32_t create(FlaxRuntime **output, FlaxError *error) {
  return protect(error, [&] {
    auto runtime = std::make_unique<FlaxRuntime>();
    runtime->js = flax::createEngineRuntime();
    runtime->arrayBufferConstructor = std::make_unique<jsi::Function>(
        runtime->js->global().getPropertyAsFunction(*runtime->js, "ArrayBuffer"));
    // Capture intrinsic getters: a view's own buffer/offset properties may lie.
    auto helper = std::make_shared<jsi::StringBuffer>(R"JS((() => {
      const getter = (p, n) => Object.getOwnPropertyDescriptor(p, n).get;
      const typed = Object.getPrototypeOf(Uint8Array.prototype);
      const tb = getter(typed, 'buffer'), to = getter(typed, 'byteOffset');
      const tl = getter(typed, 'byteLength');
      const db = getter(DataView.prototype, 'buffer');
      const dO = getter(DataView.prototype, 'byteOffset');
      const dl = getter(DataView.prototype, 'byteLength');
      const length = getter(ArrayBuffer.prototype, 'byteLength');
      const isView = ArrayBuffer.isView;
      return v => {
        if (!isView(v)) return [v, 0, length.call(v)];
        try { return [tb.call(v), to.call(v), tl.call(v)]; }
        catch (_) { return [db.call(v), dO.call(v), dl.call(v)]; }
      };
    })())JS");
    runtime->byteView = std::make_unique<jsi::Function>(
        runtime->js->evaluateJavaScript(helper, "flax:bytes")
            .getObject(*runtime->js).getFunction(*runtime->js));
    *output = runtime.release();
  });
}

int32_t destroy(FlaxRuntime *runtime, FlaxError *error) {
  return protect(error, [&] {
    if (!runtime)
      return;
    {
      std::unique_lock lock(runtime->mutex, std::try_to_lock);
      if (!lock.owns_lock() || runtime->depth != 0 || runtime->disposing) {
        throw BridgeError(FLAX_STATE_ERROR, "Cannot destroy an active runtime");
      }
      runtime->disposing = true;
      runtime->values.clear();
      runtime->byteView.reset();
      runtime->arrayBufferConstructor.reset();
      runtime->js.reset();
    }
    delete runtime;
  });
}

int32_t evaluate(FlaxRuntime *runtime, const uint8_t *source,
                 size_t sourceLength, const uint8_t *url, size_t urlLength,
                 FlaxValueId *output, FlaxError *error) {
  return enter(runtime, error, [&] {
    auto buffer =
        std::make_shared<jsi::StringBuffer>(text(source, sourceLength));
    *output = keep(
        runtime, runtime->js->evaluateJavaScript(buffer, text(url, urlLength)));
  });
}

int32_t globalObject(FlaxRuntime *runtime, FlaxValueId *output,
                     FlaxError *error) {
  return enter(runtime, error,
               [&] { *output = keep(runtime, runtime->js->global()); });
}

int32_t makeValue(FlaxRuntime *runtime, int32_t kind, double number,
                  const uint16_t *data, size_t length, FlaxValueId *output,
                  FlaxError *error) {
  return enter(runtime, error, [&] {
    switch (kind) {
    case FLAX_UNDEFINED:
      *output = keep(runtime, jsi::Value::undefined());
      break;
    case FLAX_NULL:
      *output = keep(runtime, jsi::Value::null());
      break;
    case FLAX_BOOLEAN:
      *output = keep(runtime, jsi::Value(number != 0));
      break;
    case FLAX_NUMBER:
      *output = keep(runtime, jsi::Value(number));
      break;
    case FLAX_STRING:
      *output =
          keep(runtime,
               jsi::String::createFromUtf16(*runtime->js, utf16(data, length)));
      break;
    default:
      throw BridgeError(FLAX_ARGUMENT_ERROR, "Unsupported primitive kind");
    }
  });
}

int32_t inspect(FlaxRuntime *runtime, FlaxValueId id, FlaxValueInfo *info,
                FlaxError *error) {
  return enter(runtime, error, [&] {
    *info = {};
    auto &v = value(runtime, id);
    if (v.isUndefined())
      info->kind = FLAX_UNDEFINED;
    else if (v.isNull())
      info->kind = FLAX_NULL;
    else if (v.isBool()) {
      info->kind = FLAX_BOOLEAN;
      info->number = v.getBool();
    } else if (v.isNumber()) {
      info->kind = FLAX_NUMBER;
      info->number = v.getNumber();
    } else if (v.isString()) {
      info->kind = FLAX_STRING;
      auto string = v.getString(*runtime->js).utf16(*runtime->js);
      info->string_data = reinterpret_cast<uint16_t *>(
          copyBytes(reinterpret_cast<const uint8_t *>(string.data()),
                    string.size() * sizeof(char16_t)));
      if (!info->string_data && !string.empty())
        throw std::bad_alloc();
      info->string_length = string.size();
    } else if (v.isObject()) {
      info->kind = v.getObject(*runtime->js).isFunction(*runtime->js)
                       ? FLAX_FUNCTION
                       : FLAX_OBJECT;
    } else {
      throw BridgeError(FLAX_ARGUMENT_ERROR,
                        "Symbol and BigInt conversion is not implemented");
    }
  });
}

int32_t cloneValue(FlaxRuntime *runtime, FlaxValueId id, FlaxValueId *output,
                   FlaxError *error) {
  return enter(runtime, error, [&] {
    *output = keep(runtime, jsi::Value(*runtime->js, value(runtime, id)));
  });
}

int32_t releaseValue(FlaxRuntime *runtime, FlaxValueId id, FlaxError *error) {
  return enter(runtime, error, [&] {
    if (!runtime->values.erase(id))
      throw BridgeError(FLAX_STATE_ERROR, "Released or foreign value");
  });
}

int32_t getProperty(FlaxRuntime *runtime, FlaxValueId id, const uint16_t *name,
                    size_t length, FlaxValueId *output, FlaxError *error) {
  return enter(runtime, error, [&] {
    *output =
        keep(runtime, object(runtime, id)
                          .getProperty(*runtime->js,
                                       propertyName(runtime, name, length)));
  });
}

int32_t setProperty(FlaxRuntime *runtime, FlaxValueId id, const uint16_t *name,
                    size_t length, FlaxValueId input, FlaxError *error) {
  return enter(runtime, error, [&] {
    // Copy before a setter can reenter and mutate the handle table.
    auto v = jsi::Value(*runtime->js, value(runtime, input));
    object(runtime, id)
        .setProperty(*runtime->js, propertyName(runtime, name, length), v);
  });
}

int32_t call(FlaxRuntime *runtime, FlaxValueId id, FlaxValueId thisValue,
             const FlaxValueId *arguments, size_t count, FlaxValueId *output,
             FlaxError *error) {
  return enter(runtime, error, [&] {
    auto obj = object(runtime, id);
    if (!obj.isFunction(*runtime->js))
      throw BridgeError(FLAX_ARGUMENT_ERROR, "Expected a function");
    std::vector<jsi::Value> args;
    args.reserve(count);
    for (size_t i = 0; i < count; ++i)
      args.emplace_back(*runtime->js, value(runtime, arguments[i]));
    auto receiver = thisValue
                        ? jsi::Value(*runtime->js, value(runtime, thisValue))
                        : jsi::Value::undefined();
    auto function = obj.getFunction(*runtime->js);
    // Runtime::call supports an arbitrary JS receiver, including primitives.
    *output = keep(runtime, runtime->js->call(function, receiver, args.data(),
                                              args.size()));
  });
}

int32_t strictEquals(FlaxRuntime *runtime, FlaxValueId left, FlaxValueId right,
                     int32_t *output, FlaxError *error) {
  return enter(runtime, error, [&] {
    *output = jsi::Value::strictEquals(*runtime->js, value(runtime, left),
                                       value(runtime, right));
  });
}

struct CallbackValues {
  FlaxRuntime *runtime;
  std::vector<FlaxValueId> ids;
  FlaxValueId result = 0;
  FlaxError error{};
  ~CallbackValues() {
    for (auto id : ids)
      runtime->values.erase(id);
    if (result)
      runtime->values.erase(result);
    clearError(&error);
  }
  FlaxValueId add(const jsi::Value &v) {
    const auto id = keep(runtime, jsi::Value(*runtime->js, v));
    try {
      ids.push_back(id);
    } catch (...) {
      runtime->values.erase(id);
      throw;
    }
    return id;
  }
};

int32_t registerHost(FlaxRuntime *runtime, const uint16_t *name, size_t length,
                     FlaxHostCallback callback, void *context,
                     FlaxError *error) {
  return enter(runtime, error, [&] {
    if (!callback)
      throw BridgeError(FLAX_ARGUMENT_ERROR, "Null host callback");
    auto prop = propertyName(runtime, name, length);
    auto function = jsi::Function::createFromHostFunction(
        *runtime->js, prop, 0,
        [runtime, callback,
         context](jsi::Runtime &js, const jsi::Value &receiver,
                  const jsi::Value *arguments, size_t count) {
          CallbackValues frame{runtime};
          frame.ids.reserve(count + 1);
          const auto thisId = frame.add(receiver);
          for (size_t i = 0; i < count; ++i)
            frame.add(arguments[i]);
          const auto status =
              callback(context, runtime, thisId, frame.ids.data() + 1, count,
                       &frame.result, &frame.error);
          if (status != FLAX_OK) {
            auto message =
                text(frame.error.message, frame.error.message_length);
            auto stack = text(frame.error.stack, frame.error.stack_length);
            if (!stack.empty())
              message += "\nDart host stack:\n" + stack;
            throw jsi::JSError(js, message.empty() ? "Dart host callback failed"
                                                   : message);
          }
          return jsi::Value(js, value(runtime, frame.result));
        });
    runtime->js->global().setProperty(*runtime->js, prop, std::move(function));
  });
}

int32_t drainMicrotasks(FlaxRuntime *runtime, int32_t hint, int32_t *complete,
                        FlaxError *error) {
  return enter(runtime, error, [&] {
    if (hint < -1)
      throw BridgeError(FLAX_ARGUMENT_ERROR, "Invalid microtask hint");
    if (runtime->depth > 1)
      throw BridgeError(FLAX_STATE_ERROR,
                        "Cannot drain microtasks during a callback");
    *complete = runtime->js->drainMicrotasks(hint);
  });
}

int32_t makeBytes(FlaxRuntime *runtime, const uint8_t *data, size_t length,
                  FlaxValueId *output, FlaxError *error) {
  return enter(runtime, error, [&] {
    if (!data && length)
      throw BridgeError(FLAX_ARGUMENT_ERROR, "Null byte buffer");
    if (length > 9007199254740991ULL)
      throw BridgeError(FLAX_ARGUMENT_ERROR, "Byte length exceeds JS integer precision");
    auto &js = *runtime->js;
    // Engine-owned storage can transfer even when JS properties are frozen.
    auto object = runtime->arrayBufferConstructor->callAsConstructor(
        js, static_cast<double>(length)).getObject(js);
    auto buffer = object.getArrayBuffer(js);
    if (buffer.size(js) != length)
      throw BridgeError(FLAX_STATE_ERROR, "ArrayBuffer allocation size mismatch");
    if (length) std::memcpy(buffer.data(js), data, length);
    *output = keep(runtime, std::move(object));
  });
}

int32_t readBytes(FlaxRuntime *runtime, FlaxValueId id, uint8_t **output,
                  size_t *length, FlaxError *error) {
  return enter(runtime, error, [&] {
    *output = nullptr;
    *length = 0;
    auto &js = *runtime->js;
    auto range = runtime->byteView->call(js, value(runtime, id))
                     .getObject(js).getArray(js);
    auto bufferObject = range.getValueAtIndex(js, 0).getObject(js);
    if (!bufferObject.isArrayBuffer(js))
      throw BridgeError(FLAX_ARGUMENT_ERROR, "Expected an unshared ArrayBuffer");
    auto buffer = bufferObject.getArrayBuffer(js);
    if (buffer.detached(js))
      throw BridgeError(FLAX_ARGUMENT_ERROR, "Detached ArrayBuffer");
    const auto offset = static_cast<size_t>(range.getValueAtIndex(js, 1).getNumber());
    const auto count = static_cast<size_t>(range.getValueAtIndex(js, 2).getNumber());
    if (offset > buffer.size(js) || count > buffer.size(js) - offset)
      throw BridgeError(FLAX_ARGUMENT_ERROR, "Byte view is out of bounds");
    if (count) {
      *output = copyBytes(buffer.data(js) + offset, count);
      if (!*output) throw std::bad_alloc();
    }
    *length = count;
  });
}

const FlaxApi api{
    FLAX_ABI_VERSION, sizeof(FlaxApi), create,     destroy,      evaluate,
    globalObject,     makeValue,       inspect,    cloneValue,   releaseValue,
    getProperty,      setProperty,     call,       strictEquals, registerHost,
    drainMicrotasks,  makeBytes, readBytes, std::free, clearError, setError};
} // namespace

namespace flax {
const FlaxApi *runtimeApi() { return &api; }
} // namespace flax
