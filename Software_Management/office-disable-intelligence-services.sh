#!/bin/bash

GUI_USER=$(who | grep console | grep -v '_mbsetupuser' | awk '{print $1}')
echo $GUI_USER


write_prefs(){
  sudo -u "$GUI_USER" defaults write "$1" kFREIntelligenceServicesConsentV2Key -bool TRUE
  sudo -u "$GUI_USER" defaults write "$1" PII_And_Intelligent_Services_Preference -bool FALSE

}


write_prefs "com.microsoft.Word"
write_prefs "com.microsoft.Powerpoint"
write_prefs "com.microsoft.Excel"
write_prefs "com.microsoft.Onenote"
write_prefs "com.microsoft.Outlook"

