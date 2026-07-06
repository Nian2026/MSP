#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 APP_BUNDLE PYTHON_XCFRAMEWORK OUT_DIR

Embeds the iOS simulator slice of a BeeWare Python.xcframework into an already
built MSPPlaygroundApp simulator bundle and installs the Python stdlib into the
bundle. Prints shell assignments for the app-internal CPython library and home.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$#" -ne 3 ]]; then
  usage >&2
  exit 2
fi

APP_BUNDLE="$1"
PYTHON_XCFRAMEWORK_PATH="$2"
OUT_DIR="$3"
BUNDLE_ID="${MSP_PLAYGROUND_E2E_BUNDLE_ID:-${MSP_EXAMPLE_BUNDLE_ID_PREFIX:-com.modelshellprotocol.examples}.playground}"
EXECUTABLE_NAME="${MSP_PLAYGROUND_E2E_EXECUTABLE_NAME:-MSPPlaygroundApp}"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "app bundle not found: $APP_BUNDLE" >&2
  exit 2
fi
if [[ "$PYTHON_XCFRAMEWORK_PATH" != /* ]]; then
  PYTHON_XCFRAMEWORK_PATH="$(cd "$(dirname "$PYTHON_XCFRAMEWORK_PATH")" && pwd)/$(basename "$PYTHON_XCFRAMEWORK_PATH")"
fi
if [[ ! -d "$PYTHON_XCFRAMEWORK_PATH" ]]; then
  echo "Python XCFramework not found: $PYTHON_XCFRAMEWORK_PATH" >&2
  exit 2
fi

mkdir -p "$OUT_DIR"

SAFE_PYTHON_XCFRAMEWORK_PATH="$PYTHON_XCFRAMEWORK_PATH"
TEMP_PYTHON_XCFRAMEWORK_DIR=""
if [[ "$PYTHON_XCFRAMEWORK_PATH" = /* || "$PYTHON_XCFRAMEWORK_PATH" =~ [[:space:]] ]]; then
  TEMP_PYTHON_XCFRAMEWORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/msp-playground-cpython.XXXXXX")"
  trap 'rm -rf "$TEMP_PYTHON_XCFRAMEWORK_DIR"' EXIT
  SAFE_PYTHON_XCFRAMEWORK_PATH="$TEMP_PYTHON_XCFRAMEWORK_DIR/Python.xcframework"
  ln -s "$PYTHON_XCFRAMEWORK_PATH" "$SAFE_PYTHON_XCFRAMEWORK_PATH"
fi

FRAMEWORK_SLICE="$SAFE_PYTHON_XCFRAMEWORK_PATH/ios-arm64_x86_64-simulator/Python.framework"
if [[ ! -d "$FRAMEWORK_SLICE" ]]; then
  FRAMEWORK_SLICE="$SAFE_PYTHON_XCFRAMEWORK_PATH/ios-arm64-simulator/Python.framework"
fi
if [[ ! -d "$FRAMEWORK_SLICE" ]]; then
  echo "Python XCFramework does not contain an iOS simulator slice: $PYTHON_XCFRAMEWORK_PATH" >&2
  exit 2
fi

UTILS="$SAFE_PYTHON_XCFRAMEWORK_PATH/build/utils.sh"
if [[ ! -f "$UTILS" ]]; then
  echo "Python XCFramework is missing build/utils.sh: $UTILS" >&2
  exit 2
fi

mkdir -p "$APP_BUNDLE/Frameworks"
rm -rf "$APP_BUNDLE/Frameworks/Python.framework"
rsync -a --delete "$FRAMEWORK_SLICE/" "$APP_BUNDLE/Frameworks/Python.framework/" >&2

ARCHS="${ARCHS:-}"
if [[ -z "$ARCHS" && -f "$APP_BUNDLE/$EXECUTABLE_NAME" ]]; then
  ARCHS="$(lipo -archs "$APP_BUNDLE/$EXECUTABLE_NAME" | awk '{print $1}')"
fi

export PROJECT_DIR=""
export CODESIGNING_FOLDER_PATH="$APP_BUNDLE"
export EFFECTIVE_PLATFORM_NAME="-iphonesimulator"
export ARCHS
export PLATFORM_FAMILY_NAME="iOS"
export PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
export EXPANDED_CODE_SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
export EXPANDED_CODE_SIGN_IDENTITY_NAME="${EXPANDED_CODE_SIGN_IDENTITY_NAME:--}"

{
  # shellcheck disable=SC1090
  source "$UTILS"

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

    echo "Signing framework as ${EXPANDED_CODE_SIGN_IDENTITY_NAME:-} (${EXPANDED_CODE_SIGN_IDENTITY:-})..."
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" ${OTHER_CODE_SIGN_FLAGS:-} -o runtime --timestamp=none --preserve-metadata=identifier,entitlements,flags --generate-entitlement-der "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER"
  }

  process_dylibs() {
    PYTHON_XCFRAMEWORK_PATH=$1
    LIB_PATH=$2
    find "$CODESIGNING_FOLDER_PATH/$LIB_PATH" -name "*.so" | while IFS= read -r FULL_EXT; do
      install_dylib "$PYTHON_XCFRAMEWORK_PATH" "$LIB_PATH/" "$FULL_EXT"
    done
  }

  install_python "$SAFE_PYTHON_XCFRAMEWORK_PATH"

  signing_identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
  if [[ -z "$signing_identity" ]]; then
    signing_identity="-"
  fi
  /usr/bin/codesign --force --sign "$signing_identity" --timestamp=none "$APP_BUNDLE/Frameworks/Python.framework"
  /usr/bin/codesign --force --sign "$signing_identity" --timestamp=none --preserve-metadata=identifier,entitlements,flags --generate-entitlement-der "$APP_BUNDLE"
} >&2

printf 'MSP_PLAYGROUND_EMBEDDED_CPYTHON_LIBRARY_PATH=%q\n' "$APP_BUNDLE/Frameworks/Python.framework/Python"
printf 'MSP_PLAYGROUND_EMBEDDED_CPYTHON_HOME=%q\n' "$APP_BUNDLE/python"
