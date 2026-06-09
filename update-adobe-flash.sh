#!/bin/bash

# This script downloads and installs the latest Flash player for compatible Macs

# Determine OS version
osvers=$(sw_vers -productVersion | awk -F. '{print $2}')

# Determine current major version of Adobe Flash for use
# use with the downloadURL variable
internetFlashMajorVersion=$(/usr/bin/curl --silent http://fpdownload2.macromedia.com/get/flashplayer/update/current/xml/version_en_mac_pl.xml | cut -d , -f 1 | awk -F\" '/update version/{print $NF}')
# what is the most up to date version of flash that adobe knows about
internetFlashFullVersionNumber=$(/usr/bin/curl --silent http://fpdownload2.macromedia.com/get/flashplayer/update/current/xml/version_en_mac_pl.xml | cut -d , -f 1-4 | cut -d '"' -f 2 | head -n 1 | sed s/,/./g)
echo "Newest Version: $internetFlashFullVersionNumber"
# what is the flash version of the plugin installed on the system?
localFlashFullVersionNumber=$(defaults read "/Library/Internet Plug-Ins/Flash Player.plugin/Contents/version.plist" CFBundleVersion)
echo "Local Version: $localFlashFullVersionNumber"
# URL for the download of the flash bits, if needed.
downloadURL="https://fpdownload.adobe.com/get/flashplayer/pdc/$internetFlashFullVersionNumber/install_flash_player_osx.dmg"

# Specify name of downloaded disk image, where the files will download
flashDownloadLocation="/tmp/flash.dmg"

downloadAndInstallFlash(){


if [[ ${osvers} -lt 6 ]]; then
  echo "Adobe Flash Player is not available for Mac OS X 10.5.8 or below."
fi

if [[ ${osvers} -ge 6 ]]; then
    # Download the latest Adobe Flash Player software disk image
    /usr/bin/curl --output "$flashDownloadLocation" "$downloadURL"
    # exit 1
    # Specify a /tmp/flashplayer.XXXX mountpoint for the disk image
    tempFileMount=$(/usr/bin/mktemp -d /tmp/flashplayer.XXXX)
    # Mount the latest Flash Player disk image to /tmp/flashplayer.XXXX mountpoint
    hdiutil attach "$flashDownloadLocation" -mountpoint $tempFileMount -nobrowse -noverify -noautoopen
    echo "temp mount is:$tempFileMount"

    # Install Adobe Flash Player from the installer package stored inside the disk image
    /usr/sbin/installer -verbose -pkg "$(/usr/bin/find $tempFileMount -maxdepth 4 \( -iname \*\.pkg -o -iname \*\.mpkg \))" -target "/"
    # Clean-up #
    # Unmount the Flash Player disk image from /tmp/flashplayer.XXXX
    /usr/bin/hdiutil detach "$tempFileMount"
    # Remove the /tmp/flashplayer.XXXX mountpoint
    /bin/rm -rf "$tempFileMount"
    # Remove the downloaded disk image
    /bin/rm -rf "$flashDownloadLocation"
fi
}

if [[ $localFlashFullVersionNumber != "$internetFlashFullVersionNumber" ]]; then
  downloadAndInstallFlash
else
  echo "<result>Flash is up to date. Exiting.</result>"
fi

exit 0

