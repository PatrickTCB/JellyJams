#!/bin/sh
ditto -c -k --sequesterRsrc --keepParent "Jelly Jams.app" "JellyJams-$1.zip"
generate_appcast --download-url-prefix "https://github.com/PatrickTCB/JellyJams/releases/download/v$1/" .
gh release create "v$1" --title "Jelly Jams v$1" --notes "$2" "JellyJams-$1.zip" appcast.xml
rm JellyJams-$1.zip
rm appcast.xml
rm -r Jelly\ Jams.app
