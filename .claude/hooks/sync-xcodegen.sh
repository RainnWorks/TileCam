#!/bin/bash
# PostToolUse hook (matcher: Write).
# When a .swift file is written, regenerate the Xcode project so the new/renamed file
# enters the build graph. xcodegen is fast and idempotent. This NEVER runs a full build
# and NEVER blocks — full device builds are the `verifier` agent's deliberate job.
#
# Reads the tool-call JSON on stdin; only acts if ".swift" appears in the payload.

input=$(cat)

if echo "$input" | grep -q '\.swift'; then
  cd "${CLAUDE_PROJECT_DIR:-/Users/tom/Projects/GlassView}" 2>/dev/null || exit 0
  if command -v xcodegen >/dev/null 2>&1; then
    if xcodegen generate >/dev/null 2>&1; then
      echo '{"systemMessage":"🔧 xcodegen generate ran (Swift file written) — project graph in sync."}'
    fi
  fi
fi

exit 0
