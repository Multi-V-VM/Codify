#!/bin/bash

set -euo pipefail

echo "Building Wasmer for iOS as XCFramework..."

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

find_tool() {
    local tool_name="$1"
    shift

    if command -v "$tool_name" >/dev/null 2>&1; then
        command -v "$tool_name"
        return 0
    fi

    for candidate in "$@"; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

if [ ! -d "$SCRIPT_DIR/wasmer/lib/api" ]; then
    echo "Missing local Wasmer checkout at: $SCRIPT_DIR/wasmer"
    echo "Clone it with: git clone --depth 1 --branch v6.1.0 https://github.com/wasmerio/wasmer.git wasmer"
    exit 1
fi

RUSTUP_BIN="${RUSTUP:-}"
if [ -z "$RUSTUP_BIN" ]; then
    RUSTUP_BIN="$(find_tool rustup /opt/homebrew/bin/rustup "$HOME/.cargo/bin/rustup" || true)"
fi

CARGO_BIN="${CARGO:-}"
if [ -z "$CARGO_BIN" ]; then
    CARGO_BIN="$(find_tool cargo "$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin/cargo" "$HOME/.cargo/bin/cargo" || true)"
fi

if [ -z "$RUSTUP_BIN" ] || [ -z "$CARGO_BIN" ]; then
    echo "Could not find rustup/cargo. Set RUSTUP=... and CARGO=... or install Rust targets first."
    exit 1
fi

export PATH="$(dirname "$CARGO_BIN"):$(dirname "$RUSTUP_BIN"):/opt/homebrew/opt/llvm/bin:/opt/homebrew/bin:$PATH"

# Setup LLVM for bindgen
export LLVM_CONFIG_PATH="${LLVM_CONFIG_PATH:-/opt/homebrew/opt/llvm/bin/llvm-config}"

# Get SDK paths
IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
SIM_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)

# Install iOS targets if not already installed
echo "Installing Rust iOS targets..."
"$RUSTUP_BIN" target add aarch64-apple-ios
"$RUSTUP_BIN" target add aarch64-apple-ios-sim
"$RUSTUP_BIN" target add x86_64-apple-ios

# Clean previous builds
echo "Cleaning previous builds..."
# cargo clean
rm -rf WasmerRuntime.xcframework
rm -rf target/universal-sim/release/libwasmer_ios.a

# Build for iOS device (ARM64)
echo "Building for iOS device (aarch64-apple-ios)..."
export BINDGEN_EXTRA_CLANG_ARGS="--target=arm64-apple-ios -isysroot $IOS_SDK"
"$CARGO_BIN" build --release --target aarch64-apple-ios

# Build for iOS Simulator (ARM64 - Apple Silicon Macs)
echo "Building for iOS Simulator ARM64 (aarch64-apple-ios-sim)..."
export BINDGEN_EXTRA_CLANG_ARGS="--target=arm64-apple-ios-simulator -isysroot $SIM_SDK"
"$CARGO_BIN" build --release --target aarch64-apple-ios-sim

# Build for iOS Simulator (x86_64 - Intel Macs)
echo "Building for iOS Simulator x86_64 (x86_64-apple-ios)..."
export BINDGEN_EXTRA_CLANG_ARGS="--target=x86_64-apple-ios-simulator -isysroot $SIM_SDK"
"$CARGO_BIN" build --release --target x86_64-apple-ios

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
if [ "${COPY_TO_RESOURCES:-1}" = "1" ]; then
    echo "Copying XCFramework into CodifyOne Resources..."
    rm -rf "$SCRIPT_DIR/../Resources/WasmerRuntime.xcframework"
    cp -R "$SCRIPT_DIR/WasmerRuntime.xcframework" "$SCRIPT_DIR/../Resources/WasmerRuntime.xcframework"
    echo "Installed at: $SCRIPT_DIR/../Resources/WasmerRuntime.xcframework"
fi
