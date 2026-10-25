#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/QoderMeter.app"
TMP="$ROOT/.build/QoderMeter.app"
PL="$TMP/Contents/Info.plist"

rm -rf "$TMP" "$APP"
mkdir -p "$ROOT/.build"

osacompile -l JavaScript -o "$TMP" "$ROOT/src/main.js"

set_plist() {
  local key="$1" type="$2" value="$3"
  if /usr/libexec/PlistBuddy -c "Print :$key" "$PL" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$PL"
  else
    /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$PL"
  fi
}

set_plist CFBundleIdentifier string com.qoder.meter
set_plist CFBundleName string "Qoder Meter"
set_plist CFBundleDisplayName string "Qoder 状态条"
set_plist CFBundleShortVersionString string "1.2.0"
set_plist CFBundleVersion string "4"
set_plist LSUIElement bool true
set_plist NSHighResolutionCapable bool true
set_plist LSMinimumSystemVersion string "13.0"
set_plist LSApplicationCategoryType string "public.app-category.developer-tools"

codesign --force --deep --sign - "$TMP" >/dev/null 2>&1

cp -R "$TMP" "$APP"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
rm -rf "$ROOT/.build"

echo "Built: $APP"
