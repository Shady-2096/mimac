#!/bin/sh
# Builds mimacd and installs it as a per-user LaunchAgent pointing at this
# checkout's release build. A development install: the plist references
# .build/release/mimacd, so keep the checkout where it is.
#
#   Scripts/install-collector.sh              build and (re)install
#   Scripts/install-collector.sh --uninstall  stop and remove the agent
set -e
cd "$(dirname "$0")/.."

LABEL=com.mimac.collector
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

if [ "$1" = "--uninstall" ]; then
  rm -f "$PLIST"
  echo "Removed $LABEL. History stays in ~/Library/Application Support/Mimac."
  exit 0
fi

swift build -c release
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__MIMACD_PATH__|$PWD/.build/release/mimacd|g" "LaunchAgents/$LABEL.plist" > "$PLIST"
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed $LABEL. Check it with: .build/release/mimacctl health"
