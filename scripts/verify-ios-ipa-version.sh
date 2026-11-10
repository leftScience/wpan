#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <ipa-path> <expected-version-name> <expected-version-code>" >&2
  exit 1
fi

IPA_PATH="$1"
EXPECTED_VERSION_NAME="$2"
EXPECTED_VERSION_CODE="$3"

if [[ ! -f "$IPA_PATH" ]]; then
  echo "[ERROR] IPA not found: $IPA_PATH" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

unzip -q "$IPA_PATH" "Payload/*.app/Info.plist" -d "$TMP_DIR"
INFO_PLIST="$(find "$TMP_DIR/Payload" -maxdepth 2 -name "Info.plist" | head -n 1)"

if [[ -z "$INFO_PLIST" || ! -f "$INFO_PLIST" ]]; then
  echo "[ERROR] Info.plist not found inside IPA: $IPA_PATH" >&2
  exit 1
fi

ACTUAL_VERSION_NAME="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || true)"
ACTUAL_VERSION_CODE="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST" 2>/dev/null || true)"

if [[ -z "$ACTUAL_VERSION_NAME" || -z "$ACTUAL_VERSION_CODE" ]]; then
  echo "[ERROR] Failed to parse CFBundleShortVersionString/CFBundleVersion from IPA: $IPA_PATH" >&2
  exit 1
fi

echo "IPA versionName : $ACTUAL_VERSION_NAME"
echo "IPA versionCode : $ACTUAL_VERSION_CODE"
echo "Expected name   : $EXPECTED_VERSION_NAME"
echo "Expected code   : $EXPECTED_VERSION_CODE"

if [[ "$ACTUAL_VERSION_NAME" != "$EXPECTED_VERSION_NAME" ]]; then
  echo "[ERROR] IPA versionName mismatch: expected $EXPECTED_VERSION_NAME, got $ACTUAL_VERSION_NAME" >&2
  exit 1
fi

if [[ "$ACTUAL_VERSION_CODE" != "$EXPECTED_VERSION_CODE" ]]; then
  echo "[ERROR] IPA versionCode mismatch: expected $EXPECTED_VERSION_CODE, got $ACTUAL_VERSION_CODE" >&2
  exit 1
fi

echo "[OK] IPA internal version matches expected release metadata."
