#!/bin/bash
GUI_USER=$(who | grep console | grep -v '_mbsetupuser' | awk '{print $1}') 
pmset -a sleep 0
# auto restart on power failure
pmset -a autorestart 1
pmset -a disksleep 0
pmset -a displaysleep 0
# wake for network access, so we have remote remediation in future
pmset -a womp 1

echo "pmset -g stats"
pmset -g stats
echo "######"
echo "pmset -g live"
pmset -g live
echo "######"
echo "pmset -g custom"
pmset -g custom
echo "######"

sudo -u "$GUI_USER" defaults -currentHost write com.apple.screensaver idleTime -int 0
screenSaverActivationTime=$(sudo -u "$GUI_USER" defaults -currentHost read com.apple.screensaver idleTime)

echo "screenSaverActivationTime: $screenSaverActivationTime"


