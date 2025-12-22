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

echo ""
echo "✓ Build successful!"
echo "  App bundle: $(pwd)/AudioTrace.app"
echo ""
echo "To run: open $(pwd)/AudioTrace.app"
