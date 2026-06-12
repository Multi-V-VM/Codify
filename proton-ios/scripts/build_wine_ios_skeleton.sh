#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTON_DIR="$ROOT_DIR/proton"
WINE_DIR="$PROTON_DIR/wine"
BUILD_DIR="$ROOT_DIR/build/wine-ios"
HOST_TOOLS_DIR="$ROOT_DIR/build/wine-host-tools"
SHIM_DIR="$ROOT_DIR/build/tool-shims"
INSTALL_DIR="$ROOT_DIR/build/install/ProtonIOS"

target="${1:-arm64-apple-ios}"

case "$target" in
  arm64-apple-ios)
    sdk_name="iphoneos"
    clang_target="arm64-apple-ios"
    ;;
  arm64-apple-ios-simulator)
    sdk_name="iphonesimulator"
    clang_target="arm64-apple-ios-simulator"
    ;;
  *)
    printf 'unsupported target: %s\n' "$target" >&2
    printf 'supported targets: arm64-apple-ios, arm64-apple-ios-simulator\n' >&2
    exit 2
    ;;
esac

mkdir -p "$SHIM_DIR"
ln -sf /opt/homebrew/opt/llvm/bin/llvm-dlltool "$SHIM_DIR/dlltool"
ln -sf /opt/homebrew/opt/llvm/bin/llvm-windres "$SHIM_DIR/windres"
ln -sf /opt/homebrew/opt/llvm/bin/llvm-rc "$SHIM_DIR/rc"

export PATH="$SHIM_DIR:/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/lld/bin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/libtool/libexec/gnubin:/opt/homebrew/bin:$PATH"

if [[ ! -x "$WINE_DIR/configure" ]]; then
  if [[ ! -x "$WINE_DIR/autogen.sh" ]]; then
    printf 'Wine submodule is not initialized at %s\n' "$WINE_DIR" >&2
    printf 'Run: git -C %s submodule update --init --recursive wine\n' "$PROTON_DIR" >&2
    exit 1
  fi

  printf 'Generating Wine configure script with autogen.sh\n'
  (cd "$WINE_DIR" && ./autogen.sh)
fi

if [[ ! -f "$HOST_TOOLS_DIR/tools/makedep" || ! -f "$HOST_TOOLS_DIR/tools/make_xftmpl" || ! -f "$HOST_TOOLS_DIR/nls/locale.nls" || ! -f "$HOST_TOOLS_DIR/tools/winebuild/winebuild" || ! -f "$HOST_TOOLS_DIR/tools/widl/widl" || ! -f "$HOST_TOOLS_DIR/tools/wmc/wmc" || ! -f "$HOST_TOOLS_DIR/tools/wrc/wrc" || ! -f "$HOST_TOOLS_DIR/tools/winegcc/winegcc" || ! -f "$HOST_TOOLS_DIR/tools/wine/wine" ]]; then
  printf 'Building native Wine tools for cross-compilation\n'
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
    make \
      tools/makedep \
      tools/make_xftmpl \
      nls/locale.nls \
      tools/winebuild/winebuild \
      tools/widl/widl \
      tools/wmc/wmc \
      tools/wrc/wrc \
      tools/winegcc/winegcc \
      tools/sfnt2fon \
      tools/wine/wine
  )
fi

sdk_path="$(xcrun --sdk "$sdk_name" --show-sdk-path)"
clang_path="$(xcrun --sdk "$sdk_name" --find clang)"

mkdir -p "$BUILD_DIR/$target" "$INSTALL_DIR/$target"

cat > "$BUILD_DIR/$target/config.site" <<CONFIG_SITE
ac_cv_func_fork=no
ac_cv_func_posix_spawn=yes
ac_cv_func_shm_open=no
ac_cv_func_epoll_create=no
ac_cv_header_sys_epoll_h=no
CONFIG_SITE

export CC="$clang_path -target $clang_target -isysroot $sdk_path"
export CXX="$(xcrun --sdk "$sdk_name" --find clang++) -target $clang_target -isysroot $sdk_path"
export CPPFLAGS="-DPROTON_IOS=1 -D_WINE_PORTABLE=1"
export CFLAGS=""
export LDFLAGS="-isysroot $sdk_path"
export CONFIG_SITE="$BUILD_DIR/$target/config.site"

cd "$BUILD_DIR/$target"

printf 'Configuring Wine skeleton for %s\n' "$target"
printf 'SDK: %s\n' "$sdk_path"

"$WINE_DIR/configure" \
  --host=aarch64-apple-darwin \
  --prefix="$INSTALL_DIR/$target" \
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

perl -0pi -e 's/^\tdlls\/winemac\.drv \\\n//m' Makefile
perl -0pi -e 's/ dlls\/winemac\.drv\/winemac\.res.*?dlls\/winemac\.drv\/winemac\.pot \\\n//s' Makefile
perl -0pi -e 's/ dlls\/winemac\.drv\/winemac\.so \\\n  dlls\/winemac\.drv\/aarch64-windows\/winemac\.drv//g; s/ dlls\/winemac\.drv\/winemac\.so//g' Makefile
perl -0pi -e 's/ dlls\/winemac\.drv\/aarch64-windows\/winemac\.drv//g' Makefile
perl -0pi -e 's/ -framework (AppKit|ApplicationServices|AudioToolbox|AudioUnit|Carbon|CoreAudio|CoreMIDI|DiskArbitration)//g; s/ -framework \\\n  CoreFoundation/ -framework CoreFoundation/g' Makefile

printf '\nConfigure finished. Build with:\n'
printf '  make -C %s/%s\n' "$BUILD_DIR" "$target"
