cmake_minimum_required(VERSION 3.24)

project(flax_hermes VERSION 0.0.0 LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT APPLE OR NOT CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64")
  message(FATAL_ERROR "The runtime integration currently targets macOS arm64 only.")
endif()
if(NOT EXISTS "${FLAX_ABI_ROOT}/include/flax/runtime.h")
  message(FATAL_ERROR "FLAX_CORE_NATIVE must point to the flax package native directory.")
endif()
if(NOT EXISTS "${FLAX_HERMES_SOURCE}/CMakeLists.txt")
  message(FATAL_ERROR "Run the repository native:build command to prepare pinned Hermes sources.")
endif()

set(HERMES_ENABLE_DEBUGGER OFF CACHE BOOL "" FORCE)
set(HERMES_ENABLE_TOOLS ON CACHE BOOL "" FORCE)
set(HERMES_ENABLE_TEST_SUITE OFF CACHE BOOL "" FORCE)
set(HERMES_ENABLE_INTL OFF CACHE BOOL "" FORCE)
set(HERMES_BUILD_SHARED_JSI OFF CACHE BOOL "" FORCE)
set(HERMES_BUILD_APPLE_FRAMEWORK OFF CACHE BOOL "" FORCE)
set(HERMESVM_ALLOW_JIT 0 CACHE STRING "" FORCE)
add_subdirectory("${FLAX_HERMES_SOURCE}" "${CMAKE_BINARY_DIR}/hermes" EXCLUDE_FROM_ALL)

add_library(flax_hermes SHARED
  hermes_engine.cpp
  "${FLAX_ABI_ROOT}/src/runtime.cpp")
target_include_directories(flax_hermes PRIVATE
  "${FLAX_ABI_ROOT}/include"
  "${FLAX_ABI_ROOT}/src"
  include
  "${FLAX_HERMES_SOURCE}/API"
  "${FLAX_HERMES_SOURCE}/API/jsi"
  "${FLAX_HERMES_SOURCE}/public")
target_compile_definitions(flax_hermes PRIVATE FLAX_ENGINE_ID=1)
target_link_libraries(flax_hermes PRIVATE hermesvm_a)
target_link_options(flax_hermes PRIVATE "LINKER:-exported_symbol,_flax_hermes_get_api")
set_target_properties(flax_hermes PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN YES
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
  BUILD_WITH_INSTALL_RPATH YES
  INSTALL_RPATH "@loader_path")

enable_testing()
add_executable(flax_runtime_test "${FLAX_ABI_ROOT}/tests/runtime_test.cpp")
target_include_directories(flax_runtime_test PRIVATE
  "${FLAX_ABI_ROOT}/include" include)
target_link_libraries(flax_runtime_test PRIVATE flax_hermes)
add_test(NAME flax_runtime COMMAND flax_runtime_test)
set_tests_properties(flax_runtime PROPERTIES TIMEOUT 30)
