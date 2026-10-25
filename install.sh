#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

./build.sh

DEST_DIR="${QODER_METER_INSTALL_DIR:-$HOME/Applications}"
mkdir -p "$DEST_DIR"
rm -rf "$DEST_DIR/QoderMeter.app"
cp -R "$ROOT/QoderMeter.app" "$DEST_DIR/QoderMeter.app"

echo "Installed: $DEST_DIR/QoderMeter.app"
open "$DEST_DIR/QoderMeter.app"
