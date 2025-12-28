cmake_minimum_required(VERSION 3.25)
project(AudioTrace VERSION 1.0.0 LANGUAGES CXX OBJCXX)

# Generate compile_commands.json for IDE support
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# C++23 standard
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# macOS specific settings
set(CMAKE_OSX_ARCHITECTURES "arm64")
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.4")

# Compiler flags
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wextra -Wpedantic")
set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -O3 -DNDEBUG")
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -g -O0")

# Fetch quill
include(FetchContent)
FetchContent_Declare(
    quill
    GIT_REPOSITORY https://github.com/odygrd/quill.git
    GIT_TAG v7.3.0
)
FetchContent_MakeAvailable(quill)

# AudioCore library (pure C++23)
add_library(AudioCore STATIC
    AudioCore/AudioTapManager.mm
    AudioCore/AudioTapManager.hpp
    AudioCore/AudioAnalyzer.cpp
    AudioCore/AudioAnalyzer.hpp
    AudioCore/ActivityTracker.cpp
    AudioCore/ActivityTracker.hpp
    AudioCore/RingBuffer.hpp
    AudioCore/Logger.cpp
    AudioCore/Logger.hpp
)

target_include_directories(AudioCore PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
)

# macOS frameworks for AudioCore
find_library(COREAUDIO_FRAMEWORK CoreAudio REQUIRED)
find_library(AUDIOTOOLBOX_FRAMEWORK AudioToolbox REQUIRED)

target_link_libraries(AudioCore PUBLIC
    ${COREAUDIO_FRAMEWORK}
    ${AUDIOTOOLBOX_FRAMEWORK}
    quill::quill
)

# Main application (Obj-C++ + C++)
set(MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/macOS/Resources/Info.plist")

add_executable(AudioTrace MACOSX_BUNDLE
    macOS/main.mm
    macOS/AppDelegate.mm
    macOS/AppDelegate.hpp
    macOS/StatusItem.mm
    macOS/StatusItem.hpp
    macOS/ProcessInfo.mm
    macOS/ProcessInfo.hpp
    macOS/Resources/Info.plist
)

# Link AudioCore and macOS frameworks
find_library(COCOA_FRAMEWORK Cocoa REQUIRED)
find_library(APPKIT_FRAMEWORK AppKit REQUIRED)
find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)

target_link_libraries(AudioTrace PRIVATE
    AudioCore
    ${COCOA_FRAMEWORK}
    ${APPKIT_FRAMEWORK}
    ${FOUNDATION_FRAMEWORK}
)

# Set bundle properties
set_target_properties(AudioTrace PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${MACOSX_BUNDLE_INFO_PLIST}"
    MACOSX_BUNDLE_BUNDLE_NAME "AudioTrace"
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.audiotrace.app"
    MACOSX_BUNDLE_BUNDLE_VERSION "1.0.0"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0"
    XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS "${CMAKE_CURRENT_SOURCE_DIR}/macOS/Resources/AudioTrace.entitlements"
    XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY "-"
)

# Install targets
install(TARGETS AudioTrace
    BUNDLE DESTINATION .
)
