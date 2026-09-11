#!/bin/bash
echo "Making release for $1. '$2'"
sign_update Jelly\ Jams.app
read -r -p "Update your 'appcast.xml' file with the required values and then press Enter to continue..." _
gh release create v$1 --title "Jelly Jams v$1" --notes "$2" --asset Jelly\ Jams.app --asset appcast.xml
echo "Done"
