#!/bin/zsh
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
BUILD_ROOT="$ROOT_DIR/build/apple-xcframework"
OUTPUT_DIR="$ROOT_DIR/dist"
FRAMEWORK_NAME="libical"
MIN_IOS="13.0"
MIN_MACOS="11.0"

log() {
  printf '\n==> %s\n' "$1"
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

prepare_framework() {
  local slice_dir="$1"
  local dylib_path="$2"
  local headers_src="$3"
  local framework_dir="$slice_dir/${FRAMEWORK_NAME}.framework"
  local headers_dir="$framework_dir/Headers"
  local modules_dir="$framework_dir/Modules"
  local binary_path="$framework_dir/${FRAMEWORK_NAME}"
  local install_name="@rpath/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"

  rm -rf "$framework_dir"
  mkdir -p "$headers_dir" "$modules_dir"

  cp "$dylib_path" "$binary_path"
  install_name_tool -id "$install_name" "$binary_path"

  cp -R "$headers_src/libical/." "$headers_dir/"

  cat > "$headers_dir/${FRAMEWORK_NAME}.h" <<'EOF'
#ifndef LIBICAL_FRAMEWORK_UMBRELLA_H
#define LIBICAL_FRAMEWORK_UMBRELLA_H

#include "ical.h"
#include "icalss.h"
#include "icalvcal.h"
#include "vcard.h"

#endif
EOF

  cat > "$modules_dir/module.modulemap" <<EOF
framework module ${FRAMEWORK_NAME} {
  umbrella header "${FRAMEWORK_NAME}.h"
  export *
  module * { export * }
}
EOF

  cat > "$framework_dir/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${FRAMEWORK_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>org.libical.${FRAMEWORK_NAME}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${FRAMEWORK_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>4.0.1</string>
  <key>CFBundleVersion</key>
  <string>4.0.1</string>
  <key>MinimumOSVersion</key>
  <string>1.0</string>
</dict>
</plist>
EOF
}

link_merged_dylib() {
  local sysroot="$1"
  local archs="$2"
  local output_path="$3"
  shift 3

  local sdk_path
  sdk_path=$(xcrun --sdk "$sysroot" --show-sdk-path)
  local min_flag
  case "$sysroot" in
    iphoneos)
      min_flag="-miphoneos-version-min=${MIN_IOS}"
      ;;
    iphonesimulator)
      min_flag="-mios-simulator-version-min=${MIN_IOS}"
      ;;
    macosx)
      min_flag="-mmacosx-version-min=${MIN_MACOS}"
      ;;
    *)
      echo "Unsupported sysroot: $sysroot" >&2
      exit 1
      ;;
  esac

  local arch_flags=()
  local arch
  for arch in ${(z)archs}; do
    arch_flags+=("-arch" "$arch")
  done

  xcrun clang -dynamiclib \
    -isysroot "$sdk_path" \
    "$min_flag" \
    "${arch_flags[@]}" \
    -install_name "@rpath/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}" \
    -o "$output_path" \
    "$@"
}

build_slice() {
  local name="$1"
  local sysroot="$2"
  local archs="$3"
  local deployment_flag="$4"
  local deployment_target="$5"

  local build_dir="$BUILD_ROOT/$name/build"
  local install_dir="$BUILD_ROOT/$name/install"
  local lib_dir="$install_dir/lib"
  local include_dir="$install_dir/include"
  local dylib_path="$lib_dir/lib${FRAMEWORK_NAME}.dylib"

  rm -rf "$build_dir" "$install_dir"
  mkdir -p "$build_dir" "$install_dir"

  log "Configuring $name"
  local sdk_path
  sdk_path=$(xcrun --sdk "$sysroot" --show-sdk-path)

  local cmake_c_flags="${deployment_flag}=${deployment_target}"
  local cmake_exe_linker_flags="${deployment_flag}=${deployment_target}"
  local cmake_shared_linker_flags="${deployment_flag}=${deployment_target}"

  if [[ "$sysroot" == "iphonesimulator" ]]; then
    cmake_c_flags+=" -target arm64-apple-ios${deployment_target}-simulator"
    cmake_exe_linker_flags+=" -target arm64-apple-ios${deployment_target}-simulator"
    cmake_shared_linker_flags+=" -target arm64-apple-ios${deployment_target}-simulator"
  fi

  cmake -S "$ROOT_DIR" -B "$build_dir" \
    -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DLIBICAL_STATIC=OFF \
    -DLIBICAL_CXX_BINDINGS=OFF \
    -DLIBICAL_JAVA_BINDINGS=OFF \
    -DLIBICAL_GLIB=OFF \
    -DLIBICAL_GOBJECT_INTROSPECTION=OFF \
    -DLIBICAL_GLIB_VAPI=OFF \
    -DLIBICAL_GLIB_BUILD_DOCS=OFF \
    -DLIBICAL_BUILD_DOCS=OFF \
    -DLIBICAL_BUILD_TESTING=OFF \
    -DLIBICAL_BUILD_EXAMPLES=OFF \
    -DLIBICAL_ENABLE_BUILTIN_TZDATA=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_ICU=TRUE \
    -DCMAKE_DISABLE_FIND_PACKAGE_BerkeleyDB=TRUE \
    -DCMAKE_SYSTEM_NAME=Darwin \
    -DCMAKE_OSX_SYSROOT="$sdk_path" \
    -DCMAKE_OSX_ARCHITECTURES="$archs" \
    -DCMAKE_INSTALL_PREFIX="$install_dir" \
    -DCMAKE_INSTALL_NAME_DIR="@rpath" \
    -DCMAKE_C_FLAGS="$cmake_c_flags" \
    -DCMAKE_EXE_LINKER_FLAGS="$cmake_exe_linker_flags" \
    -DCMAKE_SHARED_LINKER_FLAGS="$cmake_shared_linker_flags"

  log "Building $name"
  cmake --build "$build_dir" --target ical icalss icalvcal icalvcard

  log "Installing $name"
  cmake --install "$build_dir"

  log "Linking merged dylib for $name"
  link_merged_dylib "$sysroot" "$archs" "$dylib_path" \
    "$lib_dir/libical.dylib" \
    "$lib_dir/libicalss.dylib" \
    "$lib_dir/libicalvcal.dylib" \
    "$lib_dir/libicalvcard.dylib"

  prepare_framework "$BUILD_ROOT/$name" "$dylib_path" "$include_dir"
}

require_tool cmake
require_tool xcodebuild
require_tool install_name_tool
require_tool xcrun

rm -rf "$BUILD_ROOT" "$OUTPUT_DIR/${FRAMEWORK_NAME}.xcframework"
mkdir -p "$BUILD_ROOT" "$OUTPUT_DIR"

build_slice "ios" "iphoneos" "arm64" "-miphoneos-version-min" "$MIN_IOS"
build_slice "ios-simulator" "iphonesimulator" "arm64" "-mios-simulator-version-min" "$MIN_IOS"
build_slice "macos" "macosx" "arm64" "-mmacosx-version-min" "$MIN_MACOS"

log "Creating xcframework"
xcodebuild -create-xcframework \
  -framework "$BUILD_ROOT/ios/${FRAMEWORK_NAME}.framework" \
  -framework "$BUILD_ROOT/ios-simulator/${FRAMEWORK_NAME}.framework" \
  -framework "$BUILD_ROOT/macos/${FRAMEWORK_NAME}.framework" \
  -output "$OUTPUT_DIR/${FRAMEWORK_NAME}.xcframework"

log "Done: $OUTPUT_DIR/${FRAMEWORK_NAME}.xcframework"
