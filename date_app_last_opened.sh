#!/bin/bash
if [[ "$1" == "" ]]; then
	echo "No App Specified, exiting"
	exit 1
fi
datetime=$(mdls "$1" -name kMDItemLastUsedDate | awk '{print $3,$4}') 
echo "'$1' was last opened on (UTC):" 
echo $datetime 
echo "'$1' was last opened on (Local Time):" 
echo $(date -jf "%Y-%m-%d %H:%M:%S %z" "$datetime +0000" +"%Y-%m-%d %H:%M:%S")