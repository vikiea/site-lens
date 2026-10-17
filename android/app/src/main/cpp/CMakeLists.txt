cmake_minimum_required(VERSION 3.22.1)
project(site_lens_export)

add_library(site_lens_export SHARED native_export.cpp)
find_library(log-lib log)
target_compile_features(site_lens_export PRIVATE cxx_std_17)
target_link_libraries(site_lens_export ${log-lib})
