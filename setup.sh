#!/usr/bin/env bash
set -euo pipefail

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required. Install it with: brew install xcodegen"
  exit 1
fi

if [ ! -f Config/Secrets.xcconfig ]; then
  cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig
  echo "Created Config/Secrets.xcconfig. Fill in Supabase values before running the app."
fi

xcodegen generate
echo "Generated Moss.xcodeproj"
echo "Next: open Moss.xcodeproj and set your Apple Development Team."

