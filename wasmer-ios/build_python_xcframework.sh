#!/bin/bash

set -e

echo "Building Wasmer Python for iOS as XCFramework..."

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Setup LLVM for bindgen
export LLVM_CONFIG_PATH=/opt/homebrew/opt/llvm/bin/llvm-config

# Get SDK paths
IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
SIM_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)

# Install iOS targets if not already installed
echo "Installing Rust iOS targets..."
rustup target add aarch64-apple-ios
rustup target add aarch64-apple-ios-sim
rustup target add x86_64-apple-ios

# Build for iOS device (ARM64)
echo "Building for iOS device (aarch64-apple-ios)..."
export BINDGEN_EXTRA_CLANG_ARGS="--target=arm64-apple-ios -isysroot $IOS_SDK"
cargo build --release --target aarch64-apple-ios

# Build for iOS Simulator (ARM64 - Apple Silicon Macs)
echo "Building for iOS Simulator ARM64 (aarch64-apple-ios-sim)..."
export BINDGEN_EXTRA_CLANG_ARGS="--target=arm64-apple-ios-simulator -isysroot $SIM_SDK"
cargo build --release --target aarch64-apple-ios-sim

# Build for iOS Simulator (x86_64 - Intel Macs)
echo "Building for iOS Simulator x86_64 (x86_64-apple-ios)..."
export BINDGEN_EXTRA_CLANG_ARGS="--target=x86_64-apple-ios-simulator -isysroot $SIM_SDK"
cargo build --release --target x86_64-apple-ios

# Create lipo binary for simulator (combine arm64-sim and x86_64)
echo "Creating universal simulator library..."
mkdir -p target/universal-sim/release
lipo -create \
    target/aarch64-apple-ios-sim/release/libwasmer_ios.a \
    target/x86_64-apple-ios/release/libwasmer_ios.a \
    -output target/universal-sim/release/libwasmer_ios.a

# Create XCFramework (Python-focused)
echo "Creating WasmerPython.xcframework..."
xcodebuild -create-xcframework \
    -library target/aarch64-apple-ios/release/libwasmer_ios.a \
    -headers include/ \
    -library target/universal-sim/release/libwasmer_ios.a \
    -headers include/ \
    -output WasmerPython.xcframework

echo ""
echo "✅ XCFramework created successfully at: $SCRIPT_DIR/WasmerPython.xcframework"
echo ""
echo "Next steps:"
echo "1. Add a Python WASM runtime (e.g., CPython WASI) to your app bundle."
echo "2. Link WasmerPython.xcframework into your app."
echo "3. Call wasmer_python_execute(...) with the runtime bytes and desired argv."

