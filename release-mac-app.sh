#!/bin/bash
echo "Making release for $1. '$2'"
cp ~/Applications/JellyJams.app .
zip -r JellyJams-$1.zip JellyJams.app
echo "SHA265 hash: $(sha256sum JellyJams-$1.zip)"
gh release create v$1 --title "Jelly Jams v$1" --notes "$2" JellyJams-$1.zip
echo "Done"
