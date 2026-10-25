#!/bin/bash
mkdir -p "$HOME/Library/Application Support/QoderMeter"
touch "$HOME/Library/Application Support/QoderMeter/autostart-paused"
APP="$(cd "$(dirname "$0")" && pwd)/QoderMeter.app"
pkill -f "^$APP/Contents/MacOS/applet$" 2>/dev/null || true
