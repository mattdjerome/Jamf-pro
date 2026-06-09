#!/bin/bash

##########################################
# Jamf Restricted Software GUI (dialog)
# Full ready-to-run version with validation
##########################################

# === DEFAULT VARIABLES ===
client_id=""
client_secret=""
jamf_url=""
log_file="/tmp/add_restricted_software.log"
tmp_xml="/tmp/restricted_sw.xml"

# === 0️⃣ Ensure log file exists ===
if [[ ! -f "$log_file" ]]; then
    mkdir -p "$(dirname "$log_file")"
    touch "$log_file"
    chmod 644 "$log_file"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | Log file created" >> "$log_file"
fi

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$log_file"
}

log "Script started"

# === 1️⃣ Ensure SwiftDialog (dialog binary) exists ===
if ! command -v dialog &> /dev/null; then
    log "SwiftDialog not found, installing from GitHub..."
    tmp_pkg="/tmp/SwiftDialog.pkg"
    curl -L -o "$tmp_pkg" "https://github.com/swiftDialog/swiftDialog/releases/latest/download/SwiftDialog.pkg"
    if [[ -f "$tmp_pkg" ]]; then
        sudo installer -pkg "$tmp_pkg" -target /
        rm -f "$tmp_pkg"
        log "SwiftDialog installed successfully"
    else
        log "❌ Failed to download SwiftDialog pkg"
        exit 1
    fi
fi

##########################################
# 2️⃣ OAuth Authentication (empty token for site fetch)
##########################################
# Prompt credentials later for OAuth; we'll use placeholders for site fetch
access_token=""

##########################################
# 3️⃣ Main GUI with all fields
##########################################
dialog_output=$(dialog \
    --title "Add Restricted Software" \
    --width 750 --height 750 \
    --message "Enter Jamf credentials and restriction details" \
    --icon "SF=shield.slash" \
    --textfield "Jamf URL",required \
    --textfield "Client ID",required\
    --textfield "Client Secret",secure,required \
    --textfield "Log File" "$log_file",required \
    --textfield "Restriction Name",required \
    --textfield "App Name",required \
    --textfield "Process Name",required \
    --textfield "Display Message",required \
    --textfield "Computers (comma-separated)" \
    --textfield "Computer Groups (comma-separated)" \
    --textfield "Exclude Computers (comma-separated)" \
    --textfield "Exclude Groups (comma-separated)" \
    --checkbox "All Computers" \
    --checkbox "Match Exact Process Name" \
    --checkbox "Send Notification" \
    --checkbox "Delete Executable" \
    --checkbox "Kill Process" \
    --button1 "Add Restriction" \
    --button2 "Cancel")

# === 4️⃣ Parse GUI output ===
restriction_name=""
app_name=""
process_name=""
display_message=""
site_selected="None"
all_computers="false"
match_exact="false"
send_notification="false"
delete_executable="false"
kill_process="false"
computers_selected=""
groups_selected=""
exclusion_computers_selected=""
exclusion_groups_selected=""

while IFS= read -r line; do
  key=$(echo "$line" | cut -d':' -f1 | xargs)
  val=$(echo "$line" | cut -d':' -f2- | xargs)
  case "$key" in
    "Jamf URL") jamf_url="$val" ;;
    "Client ID") client_id="$val" ;;
    "Client Secret") client_secret="$val" ;;
    "Log File") log_file="$val" ;;
    "Restriction Name") restriction_name="$val" ;;
    "App Name") app_name="$val" ;;
    "Process Name") process_name="$val" ;;
    "Display Message") display_message="$val" ;;
    "All Computers")
        [[ "$val" == "1" ]] && all_computers="true" || all_computers="false"
        if [[ "$all_computers" == "true" ]]; then
            computers_selected=""
            groups_selected=""
        fi
        ;;
    "Match Exact Process Name") [[ "$val" == "1" ]] && match_exact="true" || match_exact="false" ;;
    "Send Notification") [[ "$val" == "1" ]] && send_notification="true" || send_notification="false" ;;
    "Delete Executable") [[ "$val" == "1" ]] && delete_executable="true" || delete_executable="false" ;;
    "Kill Process") [[ "$val" == "1" ]] && kill_process="true" || kill_process="false" ;;
    "Computers (comma-separated)") computers_selected="$val" ;;
    "Computer Groups (comma-separated)") groups_selected="$val" ;;
    "Exclude Computers (comma-separated)") exclusion_computers_selected="$val" ;;
    "Exclude Groups (comma-separated)") exclusion_groups_selected="$val" ;;
  esac
done <<< "$dialog_output"

log "User input parsed: $restriction_name, $app_name, All Computers=$all_computers"

##########################################
# 5️⃣ Validation
##########################################
required_fields=(
  "Jamf URL::$jamf_url"
  "Client ID::$client_id"
  "Client Secret::$client_secret"
  "Restriction Name::$restriction_name"
  "App Name::$app_name"
  "Process Name::$process_name"
)

for field in "${required_fields[@]}"; do
  name="${field%%::*}"
  val="${field##*::}"
  if [[ -z "$val" ]]; then
    dialog --title "Error" --message "❌ $name is required" --button1 "OK"
    log "Validation failed: $name is empty"
    exit 1
  fi
done

##########################################
# 6️⃣ OAuth Authentication
##########################################
token_response=$(curl -s -X POST "${jamf_url}/api/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "client_id=${client_id}" \
  --data-urlencode "client_secret=${client_secret}" \
  --data-urlencode "grant_type=client_credentials")

access_token=$(echo "$token_response" | plutil -extract access_token raw - 2>/dev/null)

if [[ -z "$access_token" ]]; then
  log "❌ OAuth token fetch failed: $token_response"
  dialog --title "Error" --message "❌ Failed to get OAuth token" --button1 "OK"
  exit 1
fi
log "OAuth token obtained"

##########################################
# 7️⃣ Fetch Sites for dropdown (Optional/if you want live site selection)
##########################################
site_values="None" # default
sites_json=$(curl -s -H "Authorization: Bearer $access_token" \
                 -H "Accept: application/json" \
                 "${jamf_url}/JSSResource/sites")
site_names=$(echo "$sites_json" | jq -r '.sites[]?.name' | paste -sd "," -)
[[ -n "$site_names" ]] && site_values="None,$site_names"

log "Available sites: $site_values"

##########################################
# 8️⃣ Build XML
##########################################
csv_to_xml() {
  local csv="$1"
  local tag="$2"
  local xml=""
  IFS=',' read -ra items <<< "$csv"
  for i in "${items[@]}"; do
    i=$(echo "$i" | xargs)
    [[ -n "$i" ]] && xml+="<$tag>$i</$tag>"
  done
  echo "$xml"
}

if [[ "$all_computers" == "true" ]]; then
  all_computers_xml="true"
  computers_xml=""
  groups_xml=""
else
  all_computers_xml="false"
  computers_xml=$(csv_to_xml "$computers_selected" "computer")
  groups_xml=$(csv_to_xml "$groups_selected" "computer_group")
fi

excl_computers_xml=$(csv_to_xml "$exclusion_computers_selected" "computer")
excl_groups_xml=$(csv_to_xml "$exclusion_groups_selected" "computer_group")

cat <<EOF > "$tmp_xml"
<?xml version="1.0" encoding="UTF-8"?>
<restricted_software>
  <general>
    <name>$restriction_name</name>
    <process_name>$process_name</process_name>
    <match_exact_process_name>$match_exact</match_exact_process_name>
    <send_notification>$send_notification</send_notification>
    <kill_process>$kill_process</kill_process>
    <delete_executable>$delete_executable</delete_executable>
    <display_message>$display_message</display_message>
    <site><name>$site_selected</name></site>
  </general>
  <scope>
    <all_computers>$all_computers_xml</all_computers>
    <computers>$computers_xml</computers>
    <computer_groups>$groups_xml</computer_groups>
    <exclusions>
      <computers>$excl_computers_xml</computers>
      <computer_groups>$excl_groups_xml</computer_groups>
    </exclusions>
  </scope>
</restricted_software>
EOF

log "XML generated at $tmp_xml"

##########################################
# 9️⃣ Create or Update Restricted Software
##########################################
existing_id=$(curl -s -H "Authorization: Bearer $access_token" \
  -H "Accept: application/json" \
  "${jamf_url}/JSSResource/restrictedsoftware" | \
  jq -r --arg NAME "$restriction_name" '.restricted_software[] | select(.name==$NAME) | .id')

if [[ -n "$existing_id" ]]; then
  log "Updating existing restriction ($existing_id)"
  response=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer $access_token" \
    -H "Content-Type: application/xml" \
    -X PUT --data-binary @"$tmp_xml" \
    "${jamf_url}/JSSResource/restrictedsoftware/id/$existing_id")
else
  log "Creating new restriction"
  response=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer $access_token" \
    -H "Content-Type: application/xml" \
    -X POST --data-binary @"$tmp_xml" \
    "${jamf_url}/JSSResource/restrictedsoftware/id/0")
fi

http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

log "Jamf API response: $http_code | $body"

rm -f "$tmp_xml"
log "Script finished successfully"
dialog --title "Done" --message "Restriction processed successfully." --button1 "OK"
