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

RUST_TOOLCHAIN="${WASMER_IOS_TOOLCHAIN:-}"
if [ -n "$RUST_TOOLCHAIN" ]; then
    echo "Using Rust toolchain override: $RUST_TOOLCHAIN"
fi

RUSTFLAGS_BASE="-C debuginfo=0 -C strip=debuginfo -C embed-bitcode=no -C link-dead-code=no"
if [ "${WASMER_IOS_Z_SMALL:-0}" = "1" ]; then
    if [ "$RUST_TOOLCHAIN" != "nightly" ] && [[ "$RUST_TOOLCHAIN" != nightly-* ]]; then
        echo "WASMER_IOS_Z_SMALL=1 requires WASMER_IOS_TOOLCHAIN=nightly or a nightly-* toolchain."
        exit 1
    fi
    if ! "$RUSTUP_BIN" run "$RUST_TOOLCHAIN" rustc -Z help 2>/dev/null | grep -qE '^[[:space:]]+-Z[[:space:]]+small[=[:space:]]'; then
        echo "The selected nightly toolchain does not support -Zsmall."
        echo "Use WASMER_IOS_RUSTFLAGS for supported nightly size flags instead."
        exit 1
    fi
    RUSTFLAGS_BASE="$RUSTFLAGS_BASE -Zsmall"
fi
export RUSTFLAGS="${RUSTFLAGS:-} $RUSTFLAGS_BASE ${WASMER_IOS_RUSTFLAGS:-}"
echo "RUSTFLAGS: $RUSTFLAGS"

cargo_build() {
    if [ -n "$RUST_TOOLCHAIN" ]; then
        "$RUSTUP_BIN" run "$RUST_TOOLCHAIN" cargo build "$@"
    else
        "$CARGO_BIN" build "$@"
    fi
}

rustup_target_add() {
    if [ -n "$RUST_TOOLCHAIN" ]; then
        "$RUSTUP_BIN" target add --toolchain "$RUST_TOOLCHAIN" "$@"
    else
        "$RUSTUP_BIN" target add "$@"
    fi
}

strip_static_library() {
    if [ "${WASMER_IOS_ARCHIVE_STRIP:-0}" != "1" ]; then
        return 0
    fi

    local library="$1"
    local strip_bin
    strip_bin="$(
        command -v llvm-strip 2>/dev/null || \
        xcrun -find llvm-strip 2>/dev/null || \
        xcrun -find strip 2>/dev/null || \
        command -v strip 2>/dev/null || \
        true
    )"
    if [ -z "$strip_bin" ]; then
        echo "warning: strip not found; leaving $library unstripped"
        return 0
    fi

    "$strip_bin" -S -x "$library" 2>/dev/null || \
        "$strip_bin" -S "$library" 2>/dev/null || \
        echo "warning: could not strip $library"
}

# Setup LLVM for bindgen
export LLVM_CONFIG_PATH="${LLVM_CONFIG_PATH:-/opt/homebrew/opt/llvm/bin/llvm-config}"

# Get SDK paths
IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
SIM_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)

# Install iOS targets if not already installed
echo "Installing Rust iOS targets..."
rustup_target_add aarch64-apple-ios
rustup_target_add aarch64-apple-ios-sim
rustup_target_add x86_64-apple-ios

# Clean previous builds
echo "Cleaning previous builds..."
# cargo clean
rm -rf WasmerRuntime.xcframework
rm -f target/aarch64-apple-ios/release/libwasmer_ios.a
rm -f target/aarch64-apple-ios-sim/release/libwasmer_ios.a
rm -f target/x86_64-apple-ios/release/libwasmer_ios.a
rm -rf target/universal-sim/release/libwasmer_ios.a

# Build for iOS device (ARM64)
echo "Building for iOS device (aarch64-apple-ios)..."
export BINDGEN_EXTRA_CLANG_ARGS="--target=arm64-apple-ios -isysroot $IOS_SDK"
cargo_build --release --target aarch64-apple-ios
strip_static_library target/aarch64-apple-ios/release/libwasmer_ios.a

# Build for iOS Simulator (ARM64 - Apple Silicon Macs)
echo "Building for iOS Simulator ARM64 (aarch64-apple-ios-sim)..."
export BINDGEN_EXTRA_CLANG_ARGS="--target=arm64-apple-ios-simulator -isysroot $SIM_SDK"
cargo_build --release --target aarch64-apple-ios-sim
strip_static_library target/aarch64-apple-ios-sim/release/libwasmer_ios.a

# Build for iOS Simulator (x86_64 - Intel Macs)
echo "Building for iOS Simulator x86_64 (x86_64-apple-ios)..."
export BINDGEN_EXTRA_CLANG_ARGS="--target=x86_64-apple-ios-simulator -isysroot $SIM_SDK"
cargo_build --release --target x86_64-apple-ios
strip_static_library target/x86_64-apple-ios/release/libwasmer_ios.a

# Create lipo binary for simulator (combine arm64-sim and x86_64)
echo "Creating universal simulator library..."
mkdir -p target/universal-sim/release
lipo -create \
    target/aarch64-apple-ios-sim/release/libwasmer_ios.a \
    target/x86_64-apple-ios/release/libwasmer_ios.a \
    -output target/universal-sim/release/libwasmer_ios.a
strip_static_library target/universal-sim/release/libwasmer_ios.a

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
