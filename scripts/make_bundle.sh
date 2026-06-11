#!/bin/sh
# Assemble the macOS .app bundle.
# Usage: make_bundle.sh <executable> <Info.plist> <config.ini> <output.app>
set -e

exe="$1"
plist="$2"
config="$3"
bundle="$4"

rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$exe" "$bundle/Contents/MacOS/"
cp "$plist" "$bundle/Contents/"
cp "$config" "$bundle/Contents/Resources/"
