#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTON_DIR="${PROTON_DIR:-"$ROOT_DIR/../proton-ios/proton"}"
WINE_DIR="$PROTON_DIR/wine"
BUILD_DIR="$ROOT_DIR/build/wine-wasm"
HOST_TOOLS_DIR="$ROOT_DIR/build/wine-host-tools"
INSTALL_DIR="$ROOT_DIR/build/install/ProtonWASM"

host="${1:-wasm32-wasi}"
clang_target="${WASI_TARGET:-wasm32-wasip1}"

for tool_bin in /opt/homebrew/opt/bison/bin /opt/homebrew/opt/flex/bin /opt/homebrew/opt/llvm/bin; do
  if [[ -d "$tool_bin" ]]; then
    PATH="$tool_bin:$PATH"
  fi
done
export PATH

if [[ "$host" != "wasm32-wasi" ]]; then
  printf 'unsupported host: %s\n' "$host" >&2
  printf 'supported targets: wasm32-wasi\n' >&2
  exit 2
fi

resolve_cmd() {
  local candidate="$1"

  if [[ "$candidate" == */* ]]; then
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    return 1
  fi

  command -v "$candidate" 2>/dev/null
}

resolve_wasi_sysroot() {
  if [[ -n "${WASI_SYSROOT:-}" ]]; then
    printf '%s\n' "$WASI_SYSROOT"
    return
  fi

  local candidates=()
  if [[ -n "${WASI_SDK_PATH:-}" ]]; then
    candidates+=("$WASI_SDK_PATH/share/wasi-sysroot")
  fi
  candidates+=(
    "/opt/wasi-sdk/share/wasi-sysroot"
    "/opt/homebrew/share/wasi-sysroot"
    "/usr/local/share/wasi-sysroot"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
}

cc="${WASI_CC:-}"
if [[ -z "$cc" ]]; then
  for candidate in \
    wasm32-wasi-clang \
    /opt/homebrew/opt/llvm/bin/clang \
    /opt/homebrew/bin/clang \
    clang; do
    if cc="$(resolve_cmd "$candidate")"; then
      break
    fi
    cc=""
  done
fi

if [[ -z "$cc" ]]; then
  printf 'missing: clang or wasm32-wasi-clang\n' >&2
  exit 1
fi

sysroot="$(resolve_wasi_sysroot || true)"
if [[ -z "$sysroot" ]]; then
  printf 'missing: WASI sysroot. Set WASI_SYSROOT or WASI_SDK_PATH.\n' >&2
  exit 1
fi

link_flags=""
link_libs="${WASI_LIBS:-}"
link_check_dir="$ROOT_DIR/build/check"
mkdir -p "$link_check_dir"
if printf 'int main(void) { return 0; }\n' | "$cc" \
  --target="$clang_target" \
  --sysroot="$sysroot" \
  -x c - \
  -o "$link_check_dir/wine_wasi_link_check.wasm" \
  >/dev/null 2>"$link_check_dir/wine_wasi_link_check.err"; then
  printf 'WASI libc link path works with default runtime libraries\n'
elif printf 'int main(void) { return 0; }\n' | "$cc" \
  --target="$clang_target" \
  --sysroot="$sysroot" \
  -nodefaultlibs \
  -lc \
  -x c - \
  -o "$link_check_dir/wine_wasi_link_check.wasm" \
  >/dev/null 2>"$link_check_dir/wine_wasi_link_check_fallback.err"; then
  printf 'WASI libc link path works with -nodefaultlibs -lc\n'
  link_flags="-nodefaultlibs"
  if [[ -z "$link_libs" ]]; then
    link_libs="-lc"
  fi
else
  printf 'WASI libc link path failed for %s\n' "$cc" >&2
  sed 's/^/  /' "$link_check_dir/wine_wasi_link_check.err" >&2
  sed 's/^/  fallback: /' "$link_check_dir/wine_wasi_link_check_fallback.err" >&2
  exit 1
fi

if [[ ! -x "$WINE_DIR/configure" ]]; then
  if [[ ! -x "$WINE_DIR/autogen.sh" ]]; then
    printf 'Wine submodule is not initialized at %s\n' "$WINE_DIR" >&2
    printf 'Run: git -C %s submodule update --init --recursive wine\n' "$PROTON_DIR" >&2
    exit 1
  fi

  printf 'Generating Wine configure script with autogen.sh\n'
  (cd "$WINE_DIR" && ./autogen.sh)
fi

if [[ ! -f "$HOST_TOOLS_DIR/Makefile" ]]; then
  printf 'Configuring native Wine tools for cross-compilation\n'
  mkdir -p "$HOST_TOOLS_DIR"
  (
    cd "$HOST_TOOLS_DIR"
    "$WINE_DIR/configure" \
      --without-alsa \
      --without-capi \
      --without-cups \
      --without-dbus \
      --without-fontconfig \
      --without-freetype \
      --without-gettext \
      --without-gphoto \
      --without-gssapi \
      --without-gstreamer \
      --without-krb5 \
      --without-netapi \
      --without-opencl \
      --without-opengl \
      --without-oss \
      --without-pcap \
      --without-pcsclite \
      --without-pulse \
      --without-sane \
      --without-sdl \
      --without-udev \
      --without-unwind \
      --without-usb \
      --without-v4l2 \
      --without-vulkan \
      --without-x
  )
fi

printf 'Building native Wine tools for cross-compilation\n'
make -C "$HOST_TOOLS_DIR" tools/makedep tools/wine/wine tools/winebuild/winebuild tools/winegcc/winegcc tools/widl/widl tools/wrc/wrc

mkdir -p "$BUILD_DIR/$host" "$INSTALL_DIR/$host"

cat > "$BUILD_DIR/$host/config.site" <<CONFIG_SITE
ac_cv_func_clone=no
ac_cv_func_dlopen=no
ac_cv_func_epoll_create=no
ac_cv_func_fork=no
ac_cv_func_mmap=no
ac_cv_func_mprotect=no
ac_cv_func_posix_spawn=no
ac_cv_func_shm_open=no
ac_cv_func_socket=no
ac_cv_func_vfork=no
ac_cv_header_dlfcn_h=no
ac_cv_header_sys_epoll_h=no
ac_cv_header_sys_mman_h=no
ac_cv_header_sys_socket_h=no
CONFIG_SITE

export CC="$cc --target=$clang_target --sysroot=$sysroot $link_flags"
export CXX="${WASI_CXX:-$cc --target=$clang_target --sysroot=$sysroot $link_flags}"
export AR="${WASI_AR:-llvm-ar}"
export RANLIB="${WASI_RANLIB:-llvm-ranlib}"
export LD="${WASI_LD:-wasm-ld}"
export NM="${WASI_NM:-llvm-nm}"
export CPPFLAGS="-DPROTON_WASM=1 -D_WINE_PORTABLE=1"
export CFLAGS="-Oz"
export LDFLAGS="--target=$clang_target --sysroot=$sysroot $link_flags"
export LIBS="$link_libs"
export CONFIG_SITE="$BUILD_DIR/$host/config.site"

cd "$BUILD_DIR/$host"

printf 'Configuring Wine skeleton for host %s\n' "$host"
printf 'Clang target: %s\n' "$clang_target"
printf 'Proton: %s\n' "$PROTON_DIR"
printf 'WASI sysroot: %s\n' "$sysroot"

"$WINE_DIR/configure" \
  --host="$host" \
  --prefix="$INSTALL_DIR/$host" \
  --with-wine-tools="$HOST_TOOLS_DIR" \
  --without-alsa \
  --without-capi \
  --without-cups \
  --without-dbus \
  --without-fontconfig \
  --without-freetype \
  --without-gettext \
  --without-gphoto \
  --without-gssapi \
  --without-gstreamer \
  --without-krb5 \
  --without-ldap \
  --without-netapi \
  --without-openal \
  --without-opencl \
  --without-opengl \
  --without-oss \
  --without-pcap \
  --without-pcsclite \
  --without-pulse \
  --without-sane \
  --without-sdl \
  --without-udev \
  --without-unwind \
  --without-usb \
  --without-v4l2 \
  --without-vulkan \
  --without-x

printf '\nConfigure finished. Build with:\n'
printf '  make -C %s/%s\n' "$BUILD_DIR" "$host"
