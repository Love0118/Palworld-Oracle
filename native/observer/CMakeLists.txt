cmake_minimum_required(VERSION 3.20)

project(palworld_observer VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_EXTENSIONS OFF)

add_executable(palworld-observer src/main.cpp)
target_compile_features(palworld-observer PRIVATE cxx_std_20)
target_compile_options(
  palworld-observer
  PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    -Werror
)

include(GNUInstallDirs)
install(TARGETS palworld-observer RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
