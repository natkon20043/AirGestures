add_library(ag_core STATIC
smoothing.cpp
gesture.cpp
config.cpp
)
target_include_directories(ag_core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_features(ag_core PUBLIC cxx_std_20)