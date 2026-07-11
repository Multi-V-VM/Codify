#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output="$root/Resources/NodeJS/rust_toolchain.wasm"
url="https://github.com/Multi-V-VM/codifyone-mrustc-native/releases/download/codifyone-wasip1-20260711/rust_toolchain.wasm"

if [ -s "$output" ]; then
    exit 0
fi

mkdir -p "$(dirname -- "$output")"
temporary="$output.download"
trap 'rm -f "$temporary"' EXIT INT TERM
curl -fL "$url" -o "$temporary"
mv "$temporary" "$output"
trap - EXIT INT TERM
