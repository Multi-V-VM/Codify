// Build script to patch WAMR for iOS compatibility
use std::env;
use std::fs;
use std::path::PathBuf;

fn main() {
    // Tell Cargo to rerun this build script if it changes
    println!("cargo:rerun-if-changed=build.rs");

    // We need to patch WAMR's iOS CMakeLists.txt to remove -mfloat-abi flag
    // This happens in the wasmer crate's build, so we use a cargo patch

    // Set environment variable to help wasmer's build script
    println!("cargo:rustc-env=WAMR_DISABLE_FLOAT_ABI=1");
}
