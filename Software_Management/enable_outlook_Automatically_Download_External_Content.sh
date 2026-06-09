#!/bin/bash

GUI_USER=$(who | grep console | grep -v '_mbsetupuser' | awk '{print $1}')
echo $GUI_USER

sudo -u $GUI_USER defaults write com.microsoft.Outlook AutomaticallyDownloadExternalContent -int 1
