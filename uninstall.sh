#!/bin/bash
set -euo pipefail

WATCH_PLIST="$HOME/Library/LaunchAgents/com.qoder.meter.watch.plist"
OLD_PLIST="$HOME/Library/LaunchAgents/com.qoder.meter.plist"
SETTINGS_DIR="$HOME/Library/Application Support/QoderMeter"
LOG_FILE="$HOME/Library/Logs/QoderMeter.log"

if [ -f "$WATCH_PLIST" ]; then
  /bin/launchctl unload -w "$WATCH_PLIST" 2>/dev/null || true
fi

rm -f "$WATCH_PLIST" "$OLD_PLIST"
pkill -f "QoderMeter.app/Contents/MacOS/applet" 2>/dev/null || true
rm -rf "$HOME/Applications/QoderMeter.app"

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$SETTINGS_DIR"
  rm -f "$LOG_FILE"
  echo "Removed app, LaunchAgent, settings and log."
else
  echo "Removed app and LaunchAgent."
  echo "Settings kept at: $SETTINGS_DIR (run with --purge to delete)"
fi
