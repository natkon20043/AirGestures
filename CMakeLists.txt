cmake_minimum_required(VERSION 3.24)
project(AirGestures LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)   # clang-tidy / editor support

option(AG_SANITIZE "Build with ASan + UBSan" OFF)

add_compile_options(-Wall -Wextra -Wconversion)
if(AG_SANITIZE)
  add_compile_options(-fsanitize=address,undefined -fno-omit-frame-pointer)
  add_link_options(-fsanitize=address,undefined)
endif()

add_subdirectory(core)
add_subdirectory(platform/macos)

enable_testing()
add_subdirectory(tests)