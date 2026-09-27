#include <hermes/hermes.h>
#include <jsi/jsi.h>
#include <iostream>
#include <stdexcept>

int main() {
  try {
    auto config = hermes::vm::RuntimeConfig::Builder()
                      .withES6BlockScoping(true)
                      .withMicrotaskQueue(true)
                      .build();
    auto runtime = facebook::hermes::makeHermesRuntime(config);
    auto source = std::make_shared<facebook::jsi::StringBuffer>(R"JS(
      (() => {
        const buffer = new ArrayBuffer(4);
        const view = new Uint8Array(buffer);
        view[0] = 42;
        const moved = buffer.transfer(8);
        if (buffer.byteLength !== 0 || view.byteLength !== 0)
          throw new Error('Transfer did not detach the source');
        const callbacks = [];
        for (let i = 0; i < 3; ++i) callbacks.push(() => i);
        if (callbacks[0]() !== 0 || callbacks[2]() !== 2)
          throw new Error('Block scoping failed');
        return new Uint8Array(moved)[0];
      })()
    )JS");
    const auto value = runtime->evaluateJavaScript(source, "sdk:hermes");
    if (!value.isNumber() || value.getNumber() != 42)
      throw std::runtime_error("Unexpected result");
    std::cout << "Hermes shared SDK: evaluation and transfer passed\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
