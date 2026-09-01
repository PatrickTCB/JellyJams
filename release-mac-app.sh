#!/bin/bash
echo "Making release for $1. '$2'"
zip -r JellyJams-$1.zip ~/Applications/JellyJams.app
gh release create v$1 --title "Jelly Jams v$1" --notes "$2" JellyJams-$1.zip
echo "Done"
