
#!/bin/bash

##Kickstart Software Update
##Written by: Trevor Sysock
#2022-08-19

#c. macOS 12 and older, software update is broken. Often devices cannot see updates, even if they're valid for that device. sThis script might fix the problem.

#Close System Preferences

osascript -e 'quit app "System Preferences"'

#wait for good  measure
sleep 2

#Delete plists that may be problematic
/usr/bin/defaults delete /Library/Preferences/com.apple.SoftwareUpdate.plist 
/bin/rm -rf /Library/Preferences/com.apple.SoftwareUpdate.plist

#Kickstart software update service
/bin/launchctl kickstart -k system/com.apple.softwareupdated

sleep 2

#Open System Preferences Updates Pane
open -b com.apple.systempreferences /System/Library/PreferencePanes/SoftwareUpdate.prefPane