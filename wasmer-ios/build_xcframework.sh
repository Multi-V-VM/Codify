#!/bin/bash

set -e

echo "Building Wasmer for iOS as XCFramework..."

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Install iOS targets if not already installed
echo "Installing Rust iOS targets..."
rustup target add aarch64-apple-ios
rustup target add aarch64-apple-ios-sim
rustup target add x86_64-apple-ios

# Clean previous builds
echo "Cleaning previous builds..."
cargo clean
rm -rf WasmerRuntime.xcframework

# Build for iOS device (ARM64)
echo "Building for iOS device (aarch64-apple-ios)..."
cargo build --release --target aarch64-apple-ios

# Build for iOS Simulator (ARM64 - Apple Silicon Macs)
echo "Building for iOS Simulator ARM64 (aarch64-apple-ios-sim)..."
cargo build --release --target aarch64-apple-ios-sim

# Build for iOS Simulator (x86_64 - Intel Macs)
echo "Building for iOS Simulator x86_64 (x86_64-apple-ios)..."
cargo build --release --target x86_64-apple-ios

# Create lipo binary for simulator (combine arm64-sim and x86_64)
echo "Creating universal simulator library..."
mkdir -p target/universal-sim/release
lipo -create \
    target/aarch64-apple-ios-sim/release/libwasmer_ios.a \
    target/x86_64-apple-ios/release/libwasmer_ios.a \
    -output target/universal-sim/release/libwasmer_ios.a

# Create XCFramework
echo "Creating XCFramework..."
xcodebuild -create-xcframework \
    -library target/aarch64-apple-ios/release/libwasmer_ios.a \
    -headers include/ \
    -library target/universal-sim/release/libwasmer_ios.a \
    -headers include/ \
    -output WasmerRuntime.xcframework

echo ""
echo "✅ XCFramework created successfully at: $SCRIPT_DIR/WasmerRuntime.xcframework"
echo ""
echo "Next steps:"
echo "1. Copy WasmerRuntime.xcframework to your Code App Resources directory:"
echo "   cp -r WasmerRuntime.xcframework ../Resources/"
echo ""
echo "2. Link it in your Xcode project"
echo "3. Use the Swift wrapper to call Wasmer functions"
