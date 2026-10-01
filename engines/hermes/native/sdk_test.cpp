#include <hermes/hermes.h>
#include <jsi/jsi.h>
#include <iostream>
#include <memory>
#include <stdexcept>

int main() {
  std::cerr << "Hermes test entered main\n";
  // JSI exceptions may retain values until their catch handler has finished.
  std::unique_ptr<facebook::jsi::Runtime> runtime;
  try {
    auto config = hermes::vm::RuntimeConfig::Builder()
                      .withES6BlockScoping(true)
                      .withMicrotaskQueue(true)
                      .build();
    std::cerr << "Creating Hermes runtime\n";
    runtime = facebook::hermes::makeHermesRuntime(config);
    auto source = std::make_shared<facebook::jsi::StringBuffer>(R"JS(
      (() => {
        const buffer = new ArrayBuffer(4);
        const view = new Uint8Array(buffer);
        view[0] = 42;
        const moved = buffer.transfer(8);
        if (buffer.byteLength !== 0 || view.byteLength !== 0)
          throw new Error('Transfer did not detach the source');
        let checks = 0;
        const throwsTypeError = (action) => {
          try { action(); } catch (error) {
            if (error instanceof TypeError) { ++checks; return; }
            throw error;
          }
          throw new Error('Detached buffer was accepted');
        };
        const constructors = [Uint8Array, Int8Array, Uint8ClampedArray,
          Uint16Array, Int16Array, Uint32Array, Int32Array,
          Float32Array, Float64Array, BigInt64Array, BigUint64Array];
        for (const Constructor of constructors) {
          for (const size of [0, 16]) {
            const source = new ArrayBuffer(size);
            const oldView = new Constructor(source);
            source.transfer();
            throwsTypeError(() => new Constructor(source));
            throwsTypeError(() => new Constructor(source, 0, 0));
            throwsTypeError(() => new Constructor(oldView));
          }
          const offsetSource = new ArrayBuffer(16);
          throwsTypeError(() => new Constructor(offsetSource, {
            valueOf() { offsetSource.transfer(); return 0; }
          }));
          const lengthSource = new ArrayBuffer(16);
          throwsTypeError(() => new Constructor(lengthSource, 0, {
            valueOf() { lengthSource.transfer(); return 0; }
          }));
          let converted = false;
          throwsTypeError(() => new Constructor(buffer, 0, {
            valueOf() { converted = true; return 0; }
          }));
          if (!converted) throw new Error('Length conversion order changed');
          if (new Constructor(new ArrayBuffer(0)).length !== 0)
            throw new Error('Attached empty buffer was rejected');
        }
        throwsTypeError(() => new DataView(buffer));
        throwsTypeError(() => buffer.transfer());
        if (checks !== 101) throw new Error('Missing detached-buffer checks');
        const callbacks = [];
        for (let i = 0; i < 3; ++i) callbacks.push(() => i);
        if (callbacks[0]() !== 0 || callbacks[2]() !== 2)
          throw new Error('Block scoping failed');
        return new Uint8Array(moved)[0];
      })()
    )JS");
    std::cerr << "Evaluating Hermes test script\n";
    const auto value = runtime->evaluateJavaScript(source, "sdk:hermes");
    std::cerr << "Hermes test script returned\n";
    if (!value.isNumber() || value.getNumber() != 42)
      throw std::runtime_error("Unexpected result");
    std::cout << "Hermes shared SDK: evaluation, transfer and 101 detached-buffer "
                 "checks passed\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
