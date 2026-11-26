#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$project_dir/build/Daymark.app"
module_cache="${DAYMARK_MODULE_CACHE:-$project_dir/build/module-cache}"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
swiftc -target "$(uname -m)-apple-macosx13.0" -module-cache-path "$module_cache" -parse-as-library -Onone \
  -framework SwiftUI -framework AppKit -framework UserNotifications \
  "$project_dir/Sources/DaymarkApp.swift" -o "$app_dir/Contents/MacOS/Daymark"
codesign --force --deep --sign - "$app_dir"
printf 'Built %s\n' "$app_dir"
