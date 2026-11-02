#!/bin/bash
cd "$(dirname "$0")"
rm -f "$HOME/Library/Application Support/QoderMeter/autostart-paused"
open "./QoderMeter.app"
