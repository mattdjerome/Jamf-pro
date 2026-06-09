#!/bin/sh

#################################
#  This will manually add the EC office wifi to a computer
#  This is to fix the old JSS using config profiles to push out the office wifi
#  This will allow that configuration profile to be removed without dropping network
#################################
# collective wifi password emer278son!

CURRENT_USER=$(stat -f%Su /dev/console)
CURRENT_USERUID=$(dscl . read /Users/$CURRENT_USER UniqueID | awk {'print $2'})

WIFI_SSID="Collective Wifi"
WIFI_PASSWORD="emer278son!"
WIFI_HARDWARE_DEVICE=$(/usr/sbin/networksetup -listallhardwareports | grep -A 1 Wi-Fi | grep Device | awk '{print $2}')
CURRENT_WIFI_SSID=$(/usr/sbin/networksetup -getairportnetwork en0 | xargs | awk '{print $4,$5}')

SSID_CHECK=$(/usr/sbin/networksetup -listpreferredwirelessnetworks "$WIFI_HARDWARE_DEVICE" | grep -i "$ipu" | xargs)

# echo $SSID_CHECK

echo "Removing old mdm profiles"
/usr/local/bin/jamf removeMdmProfile

echo "Wi-Fi on device port $WIFI_HARDWARE_DEVICE"
echo "Preferred wireless Network $SSID_CHECK"
echo "Policy running for $CURRENT_USER"


# Force a connection to the new wifi if they are on the wifi that the config profile
# controls, do nothing if they are not.
if [[ "$CURRENT_WIFI_SSID" =~ "$WIFI_SSID" ]]; then
  echo "computer is on the collective wifi network"
  /usr/sbin/networksetup -setairportnetwork "$WIFI_HARDWARE_DEVICE" "$WIFI_SSID" "$WIFI_PASSWORD"
fi

#############################################################
######## Removes SSID from Preferred Wireless List #########
#############################################################

if [[ "$SSID_CHECK" =~ "$WIFI_SSID" ]];then
    echo "Removing "$WIFI_SSID" from Preferred Networks List"
    /usr/sbin/networksetup -removepreferredwirelessnetwork "$WIFI_HARDWARE_DEVICE" "$WIFI_SSID"
    echo "Adding "$WIFI_SSID" to number 1 spot for Preferred Networks List"
    /usr/sbin/networksetup -addpreferredwirelessnetworkatindex "$WIFI_HARDWARE_DEVICE" "$WIFI_SSID" 0 WPA2 "$WIFI_PASSWORD"
else
    echo "$WIFI_SSID not in Preferred Networks List, adding to number 1 spot"
    /usr/sbin/networksetup -addpreferredwirelessnetworkatindex "$WIFI_HARDWARE_DEVICE" "$WIFI_SSID" 0 WPA2 "$WIFI_PASSWORD"
fi



# Readd all the MDM components
/usr/local/bin/jamf manage

