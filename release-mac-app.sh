#!/bin/bash
set -e
VER=$1
NOTES=$2

ditto -c -k --sequesterRsrc --keepParent "Jelly Jams.app" "JellyJams-$VER.zip"
generate_appcast --download-url-prefix "https://github.com/PatrickTCB/JellyJams/releases/download/v$VER/" .
gh release create "v$VER" --title "Jelly Jams v$VER" --notes "$NOTES" "JellyJams-$VER.zip" appcast.xml
rm JellyJams-$VER.zip
