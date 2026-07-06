#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../../.." && pwd)"

display_name="${MSP_EXAMPLE_CPYTHON_DISPLAY_NAME:-${PRODUCT_NAME:-iOS example}}"
xcframework_path="${MSP_EXAMPLE_CPYTHON_XCFRAMEWORK_PATH:-${MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH:-}}"
path_hint="${MSP_EXAMPLE_CPYTHON_PATH_HINT:-MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH}"
require_cpython="${MSP_EXAMPLE_REQUIRE_CPYTHON:-}"
require_disable_hint="${MSP_EXAMPLE_REQUIRE_CPYTHON_DISABLE_HINT:-MSP_EXAMPLE_REQUIRE_CPYTHON=0}"
auto_cache="${MSP_EXAMPLE_CPYTHON_AUTO_CACHE:-}"

if [[ -z "$xcframework_path" ]]; then
  shopt -s nullglob
  cached_xcframeworks=("$repo_root"/.build/msp-cpython-ios-cache/Python-*-iOS-support.*/Python.xcframework)
  shopt -u nullglob
  if (( ${#cached_xcframeworks[@]} > 0 )); then
    xcframework_path="${cached_xcframeworks[0]}"
    echo "Using cached CPython XCFramework: $xcframework_path"
  fi
fi

if [[ -z "$require_cpython" ]]; then
  require_cpython=1
fi
if [[ -z "$auto_cache" ]]; then
  auto_cache=1
fi

if [[ -z "$xcframework_path" && "$auto_cache" == "1" ]]; then
  cache_script="$repo_root/Conformance/Scripts/cache_beeware_cpython_apple_support.sh"
  if [[ -x "$cache_script" ]]; then
    echo "CPython iOS cache missing; populating BeeWare CPython support..."
    cache_output="$(MSP_CPYTHON_APPLE_SUPPORT_PLATFORMS=iOS "$cache_script")"
    eval "$cache_output"
    xcframework_path="${MSP_EXAMPLE_CPYTHON_XCFRAMEWORK_PATH:-${MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH:-}}"
  fi
fi

if [[ -z "$xcframework_path" ]]; then
  if [[ "$require_cpython" == "1" ]]; then
    echo "$display_name requires CPython packaging for a working python3 command." >&2
    echo "set $path_hint" >&2
    echo "or run MSP_CPYTHON_APPLE_SUPPORT_PLATFORMS=iOS Conformance/Scripts/cache_beeware_cpython_apple_support.sh" >&2
    echo "set $require_disable_hint only for non-Python build diagnostics" >&2
    exit 2
  fi
  echo "Skipping CPython packaging; set $path_hint to embed Python." >&2
  exit 0
fi

if [[ "$xcframework_path" != /* ]]; then
  xcframework_path="$(cd "$repo_root/$(dirname "$xcframework_path")" && pwd)/$(basename "$xcframework_path")"
fi

if [[ -z "${CODESIGNING_FOLDER_PATH:-}" || ! -d "${CODESIGNING_FOLDER_PATH:-}" ]]; then
  echo "CODESIGNING_FOLDER_PATH does not point at an app bundle." >&2
  exit 2
fi

if [[ ! -d "$xcframework_path" ]]; then
  echo "Python XCFramework not found: $xcframework_path" >&2
  exit 2
fi

safe_xcframework_path="$xcframework_path"
install_xcframework_path="$xcframework_path"
install_project_dir="${PROJECT_DIR:-}"
temp_xcframework_dir=""

if [[ "$xcframework_path" = /* || "$xcframework_path" =~ [[:space:]] ]]; then
  temp_root="${TMPDIR:-/tmp}"
  mkdir -p "$temp_root"
  temp_xcframework_dir="$(mktemp -d "$temp_root/msp-cpython.XXXXXX")"
  trap 'rm -rf "$temp_xcframework_dir"' EXIT
  safe_xcframework_path="$temp_xcframework_dir/Python.xcframework"
  ln -s "$xcframework_path" "$safe_xcframework_path"
  install_xcframework_path="$safe_xcframework_path"
  install_project_dir=""
fi

case "${EFFECTIVE_PLATFORM_NAME:-}" in
  -iphonesimulator)
    slice_dir="ios-arm64_x86_64-simulator"
    fallback_slice_dir="ios-arm64-simulator"
    ;;
  -iphoneos|"")
    slice_dir="ios-arm64"
    fallback_slice_dir=""
    ;;
  *)
    echo "Unsupported CPython platform: ${EFFECTIVE_PLATFORM_NAME:-<empty>}" >&2
    exit 2
    ;;
esac

framework_slice="$safe_xcframework_path/$slice_dir/Python.framework"
if [[ ! -d "$framework_slice" && -n "$fallback_slice_dir" ]]; then
  framework_slice="$safe_xcframework_path/$fallback_slice_dir/Python.framework"
fi
if [[ ! -d "$framework_slice" ]]; then
  echo "Python XCFramework does not contain a usable slice for ${EFFECTIVE_PLATFORM_NAME:-iphoneos}: $xcframework_path" >&2
  exit 2
fi

frameworks_dir="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}"
mkdir -p "$frameworks_dir"
rm -rf "$frameworks_dir/Python.framework"
rsync -a --delete "$framework_slice/" "$frameworks_dir/Python.framework/"

utils="$safe_xcframework_path/build/utils.sh"
if [[ ! -f "$utils" ]]; then
  echo "Python XCFramework is missing build/utils.sh: $utils" >&2
  exit 2
fi

executable_name="${EXECUTABLE_NAME:-${PRODUCT_NAME:-}}"
if [[ -z "${ARCHS:-}" && -n "$executable_name" && -f "$CODESIGNING_FOLDER_PATH/$executable_name" ]]; then
  ARCHS="$(lipo -archs "$CODESIGNING_FOLDER_PATH/$executable_name" | awk '{print $1}')"
  export ARCHS
fi

export PLATFORM_FAMILY_NAME="${PLATFORM_FAMILY_NAME:-iOS}"
export PRODUCT_BUNDLE_IDENTIFIER="${PRODUCT_BUNDLE_IDENTIFIER:-com.modelshellprotocol.example}"

# BeeWare's Python Apple support installs the stdlib into $CODESIGNING_FOLDER_PATH/python.
# shellcheck disable=SC1090
source "$utils"

merge_arch_lib_into_stdlib() {
  local source_root=$1
  local destination_root=$2

  while IFS= read -r -d '' source_file; do
    local relative_path="${source_file#$source_root/}"
    local destination_file="$destination_root/$relative_path"
    mkdir -p "$(dirname "$destination_file")"

    if [[ ! -e "$destination_file" ]]; then
      cp -p "$source_file" "$destination_file"
      continue
    fi

    if [[ "$source_file" == *.so && "$destination_file" == *.so ]]; then
      local merged_file="$destination_file.universal.$$"
      if lipo -create "$destination_file" "$source_file" -output "$merged_file" >/dev/null 2>&1; then
        mv "$merged_file" "$destination_file"
      else
        rm -f "$merged_file"
        cp -p "$source_file" "$destination_file"
      fi
    else
      cp -p "$source_file" "$destination_file"
    fi
  done < <(find "$source_root" -type f -print0)
}

install_stdlib() {
  local PYTHON_XCFRAMEWORK_PATH=$1
  local xcframework_root="$PROJECT_DIR/$PYTHON_XCFRAMEWORK_PATH"
  local destination_root="$CODESIGNING_FOLDER_PATH/python/lib"
  local slice_folder

  mkdir -p "$destination_root"
  case "${EFFECTIVE_PLATFORM_NAME:-}" in
    -iphonesimulator)
      echo "Installing Python modules for iOS Simulator"
      if [[ -d "$xcframework_root/ios-arm64-simulator" ]]; then
        slice_folder="ios-arm64-simulator"
      else
        slice_folder="ios-arm64_x86_64-simulator"
      fi
      ;;
    -iphoneos|"")
      echo "Installing Python modules for iOS Device"
      slice_folder="ios-arm64"
      ;;
    *)
      echo "Unsupported platform name ${EFFECTIVE_PLATFORM_NAME:-<empty>}" >&2
      exit 1
      ;;
  esac

  if [[ -d "$xcframework_root/lib" ]]; then
    rsync -au --delete "$xcframework_root/lib/" "$destination_root/"

    local archs=()
    local arch
    for arch in ${ARCHS:-}; do
      if [[ -d "$xcframework_root/$slice_folder/lib-$arch" ]]; then
        archs+=("$arch")
      fi
    done
    if (( ${#archs[@]} == 0 )); then
      while IFS= read -r arch_lib_dir; do
        archs+=("${arch_lib_dir##*/lib-}")
      done < <(find "$xcframework_root/$slice_folder" -maxdepth 1 -type d -name 'lib-*' | sort)
    fi
    if (( ${#archs[@]} == 0 )); then
      echo "Python XCFramework is missing architecture-specific stdlib for $slice_folder" >&2
      exit 2
    fi

    local first_arch="${archs[0]}"
    rsync -au "$xcframework_root/$slice_folder/lib-$first_arch/" "$destination_root/"
    for arch in "${archs[@]:1}"; do
      merge_arch_lib_into_stdlib "$xcframework_root/$slice_folder/lib-$arch" "$destination_root"
    done
  else
    rsync -au --delete "$xcframework_root/$slice_folder/lib/" "$destination_root/" --exclude 'libpython*.dylib'
  fi
}

install_dylib() {
  PYTHON_XCFRAMEWORK_PATH=$1
  INSTALL_BASE=$2
  FULL_EXT=$3

  EXT="$(basename "$FULL_EXT")"
  MODULE_PATH="$(dirname "$FULL_EXT")"
  MODULE_NAME="$(echo "$EXT" | cut -d "." -f 1)"
  RELATIVE_EXT="${FULL_EXT#$CODESIGNING_FOLDER_PATH/}"
  PYTHON_EXT="${RELATIVE_EXT/$INSTALL_BASE/}"
  FULL_MODULE_NAME="$(echo "$PYTHON_EXT" | cut -d "." -f 1 | tr "/" ".")"
  FRAMEWORK_BUNDLE_ID="$(echo "$PRODUCT_BUNDLE_IDENTIFIER.$FULL_MODULE_NAME" | tr "_" "-")"
  FRAMEWORK_FOLDER="Frameworks/$FULL_MODULE_NAME.framework"

  if [[ ! -d "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER" ]]; then
    echo "Creating framework for $RELATIVE_EXT"
    mkdir -p "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER"
    cp "$PROJECT_DIR/$PYTHON_XCFRAMEWORK_PATH/build/$PLATFORM_FAMILY_NAME-dylib-Info-template.plist" "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/Info.plist"
    plutil -replace CFBundleExecutable -string "$FULL_MODULE_NAME" "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/Info.plist"
    plutil -replace CFBundleIdentifier -string "$FRAMEWORK_BUNDLE_ID" "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/Info.plist"
  fi

  echo "Installing binary for $FRAMEWORK_FOLDER/$FULL_MODULE_NAME"
  mv "$FULL_EXT" "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/$FULL_MODULE_NAME"
  echo "$FRAMEWORK_FOLDER/$FULL_MODULE_NAME" > "${FULL_EXT%.so}.fwork"
  echo "${RELATIVE_EXT%.so}.fwork" > "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/$FULL_MODULE_NAME.origin"

  if [[ -e "$MODULE_PATH/$MODULE_NAME.xcprivacy" ]]; then
    echo "Installing XCPrivacy file for $FRAMEWORK_FOLDER/$FULL_MODULE_NAME"
    XCPRIVACY_FILE="$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/PrivacyInfo.xcprivacy"
    rm -f "$XCPRIVACY_FILE"
    mv "$MODULE_PATH/$MODULE_NAME.xcprivacy" "$XCPRIVACY_FILE"
  fi

  if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]]; then
    identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
    if [[ -z "$identity" ]]; then
      identity="-"
    fi
    echo "Signing framework as ${EXPANDED_CODE_SIGN_IDENTITY_NAME:-} ($identity)..."
    /usr/bin/codesign --force --sign "$identity" ${OTHER_CODE_SIGN_FLAGS:-} -o runtime --timestamp=none --preserve-metadata=identifier,entitlements,flags --generate-entitlement-der "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER"
  else
    echo "Skipping framework signing because CODE_SIGNING_ALLOWED=NO: $FRAMEWORK_FOLDER"
  fi
}

process_dylibs() {
  PYTHON_XCFRAMEWORK_PATH=$1
  LIB_PATH=$2
  find "$CODESIGNING_FOLDER_PATH/$LIB_PATH" -name "*.so" | while IFS= read -r FULL_EXT; do
    install_dylib "$PYTHON_XCFRAMEWORK_PATH" "$LIB_PATH/" "$FULL_EXT"
  done
}

original_project_dir="${PROJECT_DIR:-}"
PROJECT_DIR="$install_project_dir"
install_python "$install_xcframework_path"
PROJECT_DIR="$original_project_dir"

if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]]; then
  identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
  if [[ -z "$identity" ]]; then
    identity="-"
  fi
  /usr/bin/codesign --force --sign "$identity" "$frameworks_dir/Python.framework"
fi

echo "Embedded CPython runtime from $framework_slice"
