#!/bin/sh
# Assemble the macOS .app bundle.
# Usage: make_bundle.sh <executable> <Info.plist> <output.app> [<config.ini>]
# config.ini is optional — release builds ship without it and rely on the app's
# fallback lookup (next-to-executable or CWD) so users can drop their own.
set -e

exe="$1"
plist="$2"
bundle="$3"
config="${4:-}"

rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$exe" "$bundle/Contents/MacOS/"
cp "$plist" "$bundle/Contents/"
if [ -n "$config" ] && [ -f "$config" ]; then
    cp "$config" "$bundle/Contents/Resources/"
fi
