#!/bin/sh

# API login info
clientId="$1"
clientSecret="$2"
jamfProURL="$3"
sourceFile="$4"

# Obtain a Bearer Token using Client ID and Secret (OAuth2)
request=$(/usr/bin/curl --request POST \
    --url "${jamfProURL}/api/oauth/token" \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=${clientId}" \
    --data-urlencode "client_secret=${clientSecret}")

# Extract the token from the JSON
token=$(/usr/bin/plutil -extract access_token raw -o - - <<< "$request")

GroupID="$5"
GroupName="$6"
apiURL="${jamfProURL}/JSSResource/computergroups/id/${GroupID}"
echo $apiURL

while IFS=',' read -r col1; do
    computerName="FAN-"$col1
    xmlHeader='<?xml version="1.0" encoding="UTF-8" standalone="no"?>'
    apiData="<computer_group><id>$GroupID</id><name>$GroupName</name><computer_additions><computer><name>$computerName</name></computer></computer_additions></computer_group>"
    curl -X PUT "${apiURL}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/xml" \
        -d "${xmlHeader}${apiData}"
done < "$sourceFile"