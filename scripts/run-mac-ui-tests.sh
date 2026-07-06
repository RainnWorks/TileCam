#!/usr/bin/env bash
#
# Run the TileCam UI test suite on Mac Catalyst.
#
# REQUIRES AN UNLOCKED, ACTIVE DESKTOP SESSION — macOS UI tests drive the real
# window server, so they cannot run while the screen is locked or on the
# screensaver. (That's why this can't be kicked off remotely until you've logged
# in via Screen Sharing or at the machine.)
#
# First run may show a one-time prompt: "TileCamUITests-Runner wants to control
# this computer." Click Allow (or grant it in System Settings → Privacy &
# Security → Accessibility / Automation), then re-run.
#
# Usage:  ./scripts/run-mac-ui-tests.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

# Keep the display awake for the duration of this script so the session doesn't
# re-lock mid-run (caffeinate exits when this script's PID exits).
caffeinate -d -i -w "$$" &

xcodegen generate >/dev/null

xcodebuild test \
  -project TileCam.xcodeproj \
  -scheme TileCam \
  -testPlan TileCam \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  CODE_SIGNING_ALLOWED=NO

echo ""
echo "Done. (To also run the full suite on the iOS simulator, swap the -destination for"
echo " 'id=<booted-sim-udid>' — see memory/sim-test-harness.md.)"
