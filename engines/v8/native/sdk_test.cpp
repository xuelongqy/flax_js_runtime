#include <libplatform/libplatform.h>
#include <v8.h>
#include <iostream>
#include <memory>

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
  }
  isolate->Dispose();
  delete allocator;
  v8::V8::Dispose();
  v8::V8::DisposePlatform();
  if (success) std::cout << "V8 shared SDK: evaluation and interceptor passed\n";
  return success ? 0 : 1;
}
