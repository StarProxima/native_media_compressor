# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

# Project-level configuration.
set(PROJECT_NAME "native_media_compressor")
project(${PROJECT_NAME} LANGUAGES CXX)

# This value is used when generating builds using this plugin, so it must
# not be changed.
set(PLUGIN_NAME "native_media_compressor_plugin")

find_package(PkgConfig REQUIRED)
find_package(Threads REQUIRED)
# GStreamer headers are only needed at build time: the libraries are loaded
# with dlopen. Without the headers, video calls answer unsupported.
pkg_check_modules(NMC_GST QUIET gstreamer-1.0 gstreamer-pbutils-1.0 gstreamer-video-1.0)
if(NOT NMC_GST_FOUND)
  message(WARNING "native_media_compressor: GStreamer development headers not found; "
    "video compression will report unsupported. Install libgstreamer1.0-dev and "
    "libgstreamer-plugins-base1.0-dev to enable it.")
endif()

list(APPEND PLUGIN_SOURCES
  "gst_api.cc"
  "image_codec.cc"
  "media_common.cc"
  "messages.g.cc"
  "native_media_compressor_plugin.cc"
  "video_queue.cc"
  "video_transcoder.cc"
)

function(nmc_configure_target TARGET)
  apply_standard_settings(${TARGET})
  target_compile_features(${TARGET} PRIVATE cxx_std_17)
  target_link_libraries(${TARGET} PRIVATE flutter PkgConfig::GTK Threads::Threads ${CMAKE_DL_LIBS})
  if(NMC_GST_FOUND)
    target_include_directories(${TARGET} SYSTEM PRIVATE ${NMC_GST_INCLUDE_DIRS})
    target_compile_definitions(${TARGET} PRIVATE NMC_HAVE_GST_HEADERS)
  endif()
endfunction()

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  ${PLUGIN_SOURCES}
)
nmc_configure_target(${PLUGIN_NAME})

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
# --no-undefined fails the build on any direct GStreamer reference, which would
# otherwise stop the app from starting on systems without GStreamer.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  LINK_FLAGS "-Wl,--no-undefined")
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")

# List of absolute paths to libraries that should be bundled with the plugin.
set(native_media_compressor_bundled_libraries
  ""
  PARENT_SCOPE
)

# === Tests ===
# These unit tests can be run from a terminal after building the example.

# Only enable test builds when building the example (which sets this variable)
# so that plugin clients aren't building the tests.
if (${include_${PROJECT_NAME}_tests})
if(${CMAKE_VERSION} VERSION_LESS "3.11.0")
message("Unit tests require CMake 3.11.0 or later")
else()
set(TEST_RUNNER "${PROJECT_NAME}_test")
enable_testing()

# Add the Google Test dependency.
include(FetchContent)
FetchContent_Declare(
  googletest
  URL https://github.com/google/googletest/releases/download/v1.18.0/googletest-1.18.0.tar.gz
)
# Prevent overriding the parent project's compiler/linker settings
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
# Disable install commands for gtest so it doesn't end up in the bundle.
set(INSTALL_GTEST OFF CACHE BOOL "Disable installation of googletest" FORCE)

FetchContent_MakeAvailable(googletest)

# The plugin's exported API is not very useful for unit testing, so build the
# sources directly into the test binary rather than using the shared library.
add_executable(${TEST_RUNNER}
  test/native_media_compressor_plugin_test.cc
  ${PLUGIN_SOURCES}
)
nmc_configure_target(${TEST_RUNNER})
target_include_directories(${TEST_RUNNER} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(${TEST_RUNNER} PRIVATE gtest_main)

# Enable automatic test discovery.
include(GoogleTest)
gtest_discover_tests(${TEST_RUNNER})

endif()  # CMake version check
endif()  # include_${PROJECT_NAME}_tests
