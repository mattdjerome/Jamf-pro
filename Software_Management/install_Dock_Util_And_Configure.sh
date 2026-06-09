#!/bin/bash

# Pre-flight Check: Confirm Dock is running / user is at Desktop

until pgrep -q -x "Finder" && pgrep -q -x "Dock"; do
  echo "PRE-FLIGHT CHECK: Finder & Dock are NOT running; pausing for 1 second"
  sleep 1
done

echo "PRE-FLIGHT CHECK: Finder & Dock are running; proceeding …"

# Path to dockutil
DOCKUTIL="/usr/local/bin/dockutil"

# Self Service App Name
selfServce="Self Service.app"

# Get the currently logged-in user
loggedInUser=$(stat -f%Su /dev/console)

# Check if dockutil is installed
if [ ! -f "$DOCKUTIL" ]; then
  echo "dockutil not found at $DOCKUTIL, running install policy"
  # if not installed, download from jamf pro policy
  sudo jamf policy -trigger installDockutil
fi

# Safety check Not needed if running from Jamf, Jamf binary runs as root
if [ "$loggedInUser" == "root" ]; then
  echo "No user logged in. Exiting..."
  exit 0
fi
# Check for Self Service or Self Service+, default is Self Service.app
if [[ -e "/Applications/Self Service+.app/" ]];
then
  SelfService="Self Service+.app/"
fi
# Remove all existing dock items
sudo -u "$loggedInUser" "$DOCKUTIL" --remove all --no-restart "/Users/$loggedInUser"

# Create an arrary of the apps needed in the dock. To add additional apps, put a space in between each app name. Only appName.app is needed, The script will add /Applications automatically

apps=("Safari.app" "Slack.app" "Microsoft Outlook.app" "Microsoft Word.app" "Microsoft Excel.app" "Microsoft PowerPoint.app" "OneDrive.app" "Microsoft OneNote.app" "zoom.us.app" "$SelfService")

# Loop to put all of the items in apps array in the dock
for app in "${apps[@]}"; do
  if [[ -e "/Applications/$app" ]]; then
    sudo -u "$loggedInUser" "$DOCKUTIL" --add /Applications/"$app" --no-restart "/Users/$loggedInUser"
    echo "app found"
  else
    echo "ERROR: App Not Found"
  fi
done

# Restart the Dock to apply changes
sudo -u "$loggedInUser" killall Dock

exit 0