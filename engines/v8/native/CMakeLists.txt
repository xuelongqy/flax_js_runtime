cmake_minimum_required(VERSION 3.24)

project(flax_v8 VERSION 0.0.0 LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT APPLE OR NOT CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64")
  message(FATAL_ERROR "The runtime integration currently targets macOS arm64 only.")
endif()
if(NOT EXISTS "${FLAX_ABI_ROOT}/include/flax/runtime.h")
  message(FATAL_ERROR "FLAX_CORE_NATIVE must point to the flax package native directory.")
endif()
if(NOT EXISTS "${FLAX_V8_INPUTS}")
  message(FATAL_ERROR "Run the repository native:build:v8 command first.")
endif()

include("${FLAX_V8_INPUTS}")
add_library(flax_v8 SHARED
  v8_engine.cpp
  "${FLAX_ABI_ROOT}/src/runtime.cpp"
  "${FLAX_JSI_SOURCE}/jsi/jsi.cpp"
  "${FLAX_V8_ADAPTER}/src/jsi_abi/JsiAbiRuntime.cpp"
  "${FLAX_V8_ADAPTER}/src/jsi_abi/jsi_abi_v8.cpp"
  "${FLAX_V8_ADAPTER}/src/v8_core.cpp"
  "${FLAX_V8_ADAPTER}/src/MurmurHash.cpp")
target_include_directories(flax_v8 PRIVATE
  "${FLAX_JSI_SOURCE}"
  "${FLAX_ABI_ROOT}/include"
  "${FLAX_ABI_ROOT}/src"
  include
  "${FLAX_V8_ADAPTER}/src"
  "${FLAX_V8_SOURCE}/include")
target_compile_definitions(flax_v8 PRIVATE ${FLAX_V8_DEFINES}
  JSI_VERSION=20 JSI_NOEXCEPT_15=noexcept JSI_CONST_10=const JSI_NO_CONST_3=)
target_compile_options(flax_v8 PRIVATE -fno-rtti)
target_compile_definitions(flax_v8 PRIVATE FLAX_ENGINE_ID=2)
target_link_libraries(flax_v8 PRIVATE ${FLAX_V8_LIBRARIES} "-framework Foundation")
target_link_options(flax_v8 PRIVATE -fuse-ld=lld "LINKER:-exported_symbol,_flax_v8_get_api")
set_target_properties(flax_v8 PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN YES
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
  BUILD_WITH_INSTALL_RPATH YES
  INSTALL_RPATH "@loader_path")

add_executable(flax_v8_lifecycle_test lifecycle_test.cpp
  "${FLAX_JSI_SOURCE}/jsi/jsi.cpp"
  "${FLAX_V8_ADAPTER}/src/jsi_abi/JsiAbiRuntime.cpp"
  "${FLAX_V8_ADAPTER}/src/v8_core.cpp"
  "${FLAX_V8_ADAPTER}/src/MurmurHash.cpp")
target_include_directories(flax_v8_lifecycle_test PRIVATE
  "${FLAX_JSI_SOURCE}"
  "${FLAX_V8_ADAPTER}/src"
  "${FLAX_V8_SOURCE}/include")
target_compile_definitions(flax_v8_lifecycle_test PRIVATE ${FLAX_V8_DEFINES}
  JSI_VERSION=20 JSI_NOEXCEPT_15=noexcept JSI_CONST_10=const JSI_NO_CONST_3=)
target_compile_options(flax_v8_lifecycle_test PRIVATE -fno-rtti)
target_link_options(flax_v8_lifecycle_test PRIVATE -fuse-ld=lld)
target_link_libraries(flax_v8_lifecycle_test PRIVATE ${FLAX_V8_LIBRARIES} "-framework Foundation")

enable_testing()
add_executable(flax_v8_runtime_test "${FLAX_ABI_ROOT}/tests/runtime_test.cpp")
target_include_directories(flax_v8_runtime_test PRIVATE
  "${FLAX_ABI_ROOT}/include" include)
target_compile_definitions(flax_v8_runtime_test PRIVATE
  FLAX_ENGINE_HEADER="flax_v8.h" FLAX_ENGINE_API=flax_v8_get_api)
target_link_libraries(flax_v8_runtime_test PRIVATE flax_v8)
add_test(NAME flax_v8_runtime COMMAND flax_v8_runtime_test)
set_tests_properties(flax_v8_runtime PROPERTIES TIMEOUT 60)
add_test(NAME flax_v8_lifecycle COMMAND flax_v8_lifecycle_test)
set_tests_properties(flax_v8_lifecycle PROPERTIES TIMEOUT 60)
