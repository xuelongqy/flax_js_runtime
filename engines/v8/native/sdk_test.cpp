#include <libplatform/libplatform.h>
#include <v8.h>
#include <atomic>
#include <iostream>
#include <memory>
#include <string>

#ifndef FLAX_SDK_EXPECT_JIT
#error "The SDK consumer must specify the expected JIT mode"
#endif

static std::atomic<bool> probeCodeGenerated{false};

v8::Intercepted GetAnswer(v8::Local<v8::Name> property,
                          const v8::PropertyCallbackInfo<v8::Value>& info) {
  if (!property->StrictEquals(
          v8::String::NewFromUtf8Literal(info.GetIsolate(), "answer"))) {
    return v8::Intercepted::kNo;
  }
  info.GetReturnValue().Set(42);
  return v8::Intercepted::kYes;
}

int main() {
#if FLAX_SDK_EXPECT_JIT
  // Request synchronous optimization below, as upstream V8 compiler tests do.
  // A hot loop alone can finish before background compilation emits code.
  v8::V8::SetFlagsFromString("--allow-natives-syntax");
#endif
  auto platform = v8::platform::NewDefaultPlatform();
  v8::V8::InitializePlatform(platform.get());
  if (!v8::V8::Initialize()) return 1;
  auto *allocator = v8::ArrayBuffer::Allocator::NewDefaultAllocator();
  v8::Isolate::CreateParams params;
  params.array_buffer_allocator = allocator;
  auto *isolate = v8::Isolate::New(params);
  bool success = false;
  {
    v8::Isolate::Scope scope(isolate);
    v8::HandleScope handles(isolate);
    auto context = v8::Context::New(isolate);
    v8::Context::Scope contextScope(context);
    isolate->SetJitCodeEventHandler(v8::kJitCodeEventDefault,
        [](const v8::JitCodeEvent *event) {
          if (event->type == v8::JitCodeEvent::CODE_ADDED &&
              event->code_type == v8::JitCodeEvent::JIT_CODE &&
              event->name.str &&
              std::string(event->name.str, event->name.len)
                  .find("flaxSdkJitProbe") != std::string::npos) {
            probeCodeGenerated.store(true);
          }
        });
    auto source = v8::String::NewFromUtf8Literal(isolate, "21 * 2");
    v8::Local<v8::Script> script;
    v8::Local<v8::Value> result;
    success = v8::Script::Compile(context, source).ToLocal(&script) &&
        script->Run(context).ToLocal(&result) &&
        result->Int32Value(context).FromMaybe(0) == 42;
    auto function = v8::FunctionTemplate::New(isolate);
    function->InstanceTemplate()->SetHandler(
        v8::NamedPropertyHandlerConfiguration(GetAnswer));
    v8::Local<v8::Function> constructor;
    v8::Local<v8::Object> object;
    v8::Local<v8::Value> answer;
    success = success && function->GetFunction(context).ToLocal(&constructor) &&
        constructor->NewInstance(context).ToLocal(&object) &&
        object->Get(context, v8::String::NewFromUtf8Literal(isolate, "answer"))
            .ToLocal(&answer) &&
        answer->Int32Value(context).FromMaybe(0) == 42;
    auto probe = v8::String::NewFromUtf8Literal(isolate, R"JS(
      (() => {
        function flaxSdkJitProbe(x) { return x + 1; }
    )JS"
#if FLAX_SDK_EXPECT_JIT
    R"JS(
        %PrepareFunctionForOptimization(flaxSdkJitProbe);
        flaxSdkJitProbe(0);
        flaxSdkJitProbe(1);
        %OptimizeFunctionOnNextCall(flaxSdkJitProbe);
        flaxSdkJitProbe(2);
    )JS"
#endif
    R"JS(
        let answer = 0;
        for (let i = 0; i < 1000000; ++i) answer = flaxSdkJitProbe(i);
        return answer;
      })()
    )JS");
    success = success && v8::Script::Compile(context, probe).ToLocal(&script) &&
        script->Run(context).ToLocal(&result) &&
        result->Int32Value(context).FromMaybe(0) == 1000000;
    if (probeCodeGenerated.load() != (FLAX_SDK_EXPECT_JIT != 0)) {
      std::cerr << "Unexpected machine-code generation for "
                << (FLAX_SDK_EXPECT_JIT ? "JIT" : "jitless") << " SDK\n";
      success = false;
    }
  }
  isolate->Dispose();
  delete allocator;
  v8::V8::Dispose();
  v8::V8::DisposePlatform();
  if (success) {
    std::cout << "V8 shared SDK: evaluation, interceptor and "
              << (FLAX_SDK_EXPECT_JIT ? "JIT" : "jitless") << " passed\n";
  }
  return success ? 0 : 1;
}
