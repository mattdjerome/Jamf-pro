#!/bin/sh
# IMPORTANT NOTE: For this to work, the computer names must be in a CSV with no other data. Otherwise it'll error out. Also, don't rename an xls to csv. Create a whole new document.

#API login info
apiuser="$1"
apipass="$2"
jamfProURL="$3"
sourceFile="$4"

# Obtain a Bearer Token using Basic Authentication, write the output into a variable
request=$(/usr/bin/curl --request POST --url ${jamfProURL}/api/v1/auth/token --header 'accept: application/json' --user "${apiuser}:${apipass}" )

# Extract the token from the JSON
token=$(/usr/bin/plutil -extract token raw -o - - <<< "$request")

GroupID="$5"
GroupName="$6"
apiURL="${jamfProURL}/JSSResource/computergroups/id/${GroupID}"
while IFS=',' read -r col1
do
    echo $col1
    xmlHeader='<?xml version="1.0" encoding="UTF-8" standalone="no"?>'
    apiData="<computer_group><id>$GroupID</id><name>$GroupName</name><computer_additions><computer><name>$col1</name></computer></computer_additions></computer_group>"
    curl -X PUT "${apiURL}" -H "Authorization: Bearer ${token}" -H "Content-Type: application/xml" -d "${xmlHeader}${apiData}"
done < $sourceFile 
