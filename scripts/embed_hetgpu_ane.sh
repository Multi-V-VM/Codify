#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
HETGPU_ROOT="${CODIFYONE_HETGPU_SOURCE_ROOT:-$PROJECT_ROOT/hetgpu-ios}"
SOURCE_DIST="${CODIFYONE_HETGPU_DIST:-$HETGPU_ROOT/dist/apple-ane}"
RESOURCE_ROOT="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
DEST_DIST="$RESOURCE_ROOT/hetgpu-apple-ane"
HETGPU_XCFRAMEWORK="$PROJECT_ROOT/Resources/HetGPUAppleRuntime.xcframework"

embed_ios_system_framework() {
    local xcframework="$PROJECT_ROOT/Resources/Term/ios_system.xcframework"
    local library_identifier=""

    case "${PLATFORM_NAME:-}" in
        iphoneos)
            library_identifier="ios-arm64"
            ;;
        iphonesimulator)
            library_identifier="ios-arm64_x86_64-simulator"
            ;;
        macosx)
            if [[ "${EFFECTIVE_PLATFORM_NAME:-}" == *maccatalyst* ]]; then
                library_identifier="ios-arm64_x86_64-maccatalyst"
            fi
            ;;
    esac

    if [[ -z "$library_identifier" ]]; then
        echo "Skipping ios_system embed for unsupported platform: ${PLATFORM_NAME:-unknown}"
        return 0
    fi

    local source_framework="$xcframework/$library_identifier/ios_system.framework"
    local frameworks_folder="${FRAMEWORKS_FOLDER_PATH:-}"

    if [[ -z "$frameworks_folder" ]]; then
        echo "Skipping ios_system embed because FRAMEWORKS_FOLDER_PATH is empty"
        return 0
    fi

    if [[ ! -d "$source_framework" ]]; then
        echo "error: ios_system framework slice not found at $source_framework" >&2
        exit 1
    fi

    local destination_dir="${TARGET_BUILD_DIR:?}/$frameworks_folder"
    local destination_framework="$destination_dir/ios_system.framework"

    rm -rf "$destination_framework"
    mkdir -p "$destination_dir"
    ditto "$source_framework" "$destination_framework"
    rm -rf "$destination_framework/Headers" "$destination_framework/PrivateHeaders"

    if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]]; then
        local signing_identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
        if [[ -z "$signing_identity" ]]; then
            signing_identity="-"
        fi
        /usr/bin/codesign --force --sign "$signing_identity" --timestamp=none "$destination_framework"
    fi

    if [[ ! -f "$destination_framework/ios_system" ]]; then
        echo "error: embedded ios_system framework is missing its binary at $destination_framework/ios_system" >&2
        exit 1
    fi

    echo "Embedded ios_system framework at $destination_framework"
}

embed_ios_system_framework

if [[ "${CODIFYONE_SKIP_HETGPU_ANE:-0}" == "1" ]]; then
    echo "Skipping hetGPU ANE embed because CODIFYONE_SKIP_HETGPU_ANE=1"
    exit 0
fi

if [[ ! -f "$SOURCE_DIST/libcuda.so.1" ]]; then
    if [[ -f "$HETGPU_XCFRAMEWORK/ios-arm64/libhetgpu_apple_runtime.a" ]]; then
        echo "Skipping hetGPU command runtime embed; using bundled HetGPUAppleRuntime.xcframework"
        exit 0
    elif [[ -x "$HETGPU_ROOT/scripts/hetgpu-ane" ]]; then
        echo "Building hetGPU Apple ANE runtime"
        "$HETGPU_ROOT/scripts/hetgpu-ane" build
    else
        echo "error: hetGPU runtime not found at $SOURCE_DIST and $HETGPU_ROOT/scripts/hetgpu-ane is missing" >&2
        exit 1
    fi
fi

if [[ ! -f "$SOURCE_DIST/libcuda.so.1" ]]; then
    echo "error: hetGPU runtime build did not produce $SOURCE_DIST/libcuda.so.1" >&2
    exit 1
fi

rm -rf "$DEST_DIST"
mkdir -p "$DEST_DIST"
ditto "$SOURCE_DIST" "$DEST_DIST"

cat > "$DEST_DIST/hetgpu-ane" <<'EOF'
#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BACKEND="${HETGPU_APPLE_BACKEND:-ane}"

usage() {
    cat <<'USAGE'
hetgpu-ane: run CodifyOne binaries through the bundled Apple ANE/Metal CUDA runtime

Usage:
  hetgpu-ane env
  hetgpu-ane doctor
  hetgpu-ane run [--backend ane|metal] -- <binary> [args...]

Examples:
  hetgpu-ane doctor
  hetgpu-ane run --backend ane -- ./infer model.bin
  hetgpu-ane run --backend metal -- ./infer
USAGE
}

export_runtime_env() {
    export CODIFYONE_HETGPU_ROOT="$SCRIPT_DIR"
    export HETGPU_APPLE_BACKEND="$BACKEND"
    export DYLD_LIBRARY_PATH="$SCRIPT_DIR:${DYLD_LIBRARY_PATH:-}"
    export DYLD_FALLBACK_LIBRARY_PATH="$SCRIPT_DIR:${DYLD_FALLBACK_LIBRARY_PATH:-}"
    export LD_LIBRARY_PATH="$SCRIPT_DIR:${LD_LIBRARY_PATH:-}"
    export DYLD_INSERT_LIBRARIES="$SCRIPT_DIR/libcuda.so.1${DYLD_INSERT_LIBRARIES:+:$DYLD_INSERT_LIBRARIES}"
}

cmd="${1:-help}"
shift || true

while [ "$#" -gt 0 ]; do
    case "$1" in
        --backend)
            shift
            [ "$#" -gt 0 ] || { echo "hetgpu-ane: --backend requires ane or metal" >&2; exit 2; }
            BACKEND="$1"
            [ "$BACKEND" = "ane" ] || [ "$BACKEND" = "metal" ] || {
                echo "hetgpu-ane: --backend must be ane or metal" >&2
                exit 2
            }
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            break
            ;;
    esac
done

case "$cmd" in
    env)
        export_runtime_env
        env | grep -E '^(CODIFYONE_HETGPU_ROOT|HETGPU_APPLE_BACKEND|DYLD_LIBRARY_PATH|DYLD_FALLBACK_LIBRARY_PATH|LD_LIBRARY_PATH|DYLD_INSERT_LIBRARIES)='
        ;;
    doctor)
        test -f "$SCRIPT_DIR/libcuda.so.1" || { echo "missing libcuda.so.1" >&2; exit 1; }
        test -f "$SCRIPT_DIR/libcublas.so.12" || { echo "missing libcublas.so.12" >&2; exit 1; }
        test -f "$SCRIPT_DIR/libcublasLt.so.12" || { echo "missing libcublasLt.so.12" >&2; exit 1; }
        echo "hetgpu-ane: ok ($SCRIPT_DIR)"
        ;;
    run)
        [ "$#" -gt 0 ] || { echo "hetgpu-ane: run needs a binary after --" >&2; exit 2; }
        export_runtime_env
        exec "$@"
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
EOF

chmod +x "$DEST_DIST/hetgpu-ane"
echo "Embedded hetGPU Apple ANE runtime at $DEST_DIST"
