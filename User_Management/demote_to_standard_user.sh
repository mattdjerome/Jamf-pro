#!/bin/sh

IFS=$'
'
declare -a localusers=($(dscl . list /Users UniqueID | grep -v -E '^(itsupport|Jamf-admin)$' | awk '$2 >= 500 && $2 < 1000 {print $1}'))
unset IFS

for i in "${localusers[@]}"
do          
    /usr/sbin/dseditgroup -o edit -n /Local/Default -d $i -t "user" "admin"
done
