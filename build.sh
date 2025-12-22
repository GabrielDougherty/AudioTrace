#!/bin/bash
set -e

# Build script for AudioTrace using Ninja

BUILD_DIR="build"

# Create build directory if it doesn't exist
mkdir -p "$BUILD_DIR"

# Configure with CMake using Ninja generator
cd "$BUILD_DIR"
CC=/usr/bin/clang CXX=/usr/bin/clang++ cmake -G Ninja ..

# Build
ninja

# Ad-hoc code signing with entitlements (for development)
echo ""
echo "Signing app bundle..."
codesign --force --deep --sign - \
    --entitlements ../macOS/Resources/AudioTrace.entitlements \
    --timestamp=none \
    AudioTrace.app

echo ""
echo "✓ Build successful!"
echo "  App bundle: $(pwd)/AudioTrace.app"
echo ""
echo "To run: open $(pwd)/AudioTrace.app"
echo "  or:   $(pwd)/AudioTrace.app/Contents/MacOS/AudioTrace"
