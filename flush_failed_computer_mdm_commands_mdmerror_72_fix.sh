#!/bin/bash
#
# Author: Johan McGwire - Yohan @ Macadmins Slack - Johan@McGwire.tech
#
# Description: Flushes failed API commands for the device the script is run on and updates inventory to trigger a re-push of those applications

# Checking if the Jamf API Username is passed
# if [ -z $4 ];then
#     read -p "Please enter the Jamf API username: " apiUser
# else 
apiUser=api_user
# fi

# Checking if the Jamf API Password is passed
# if [ -z $4 ];then
#     read -p "Please enter the Jamf API password: " apiPass
# else 
apiPass="pPxoziH59Y2j1DASIoa0n1"
# fi

# Getting the Jamf address
jamfURL=$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url)
echo "$jamfURL"
# Getting the computer serial number
serialNumber=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')
# serialNumber="C02W90KRHV2J"
echo "$serialNumber"
# Getting the computer Jamf record ID
jamfComputerID=$(curl -H "Accept: text/xml" -sfku "${apiUser}:${apiPass}" "${jamfURL}JSSResource/computers/serialnumber/${serialNumber}/subset/general" | xmllint --xpath '/computer/general/id/text()' -)
echo "$jamfComputerID"

# Removing pending appdownload application entries
find /Applications -name "*.appdownload" -maxdepth 1 | xargs rm -rf

# Wiping the Failed MDM commands
curl -X DELETE -H "accept: application/xml" -sfku "${apiUser}:${apiPass}" "${jamfURL}JSSResource/commandflush/computers/id/${jamfComputerID}/status/Failed" 

# exiting with the wipe return code
exit $?
