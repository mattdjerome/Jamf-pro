#!/bin/bash

# =============================================================================
# jamf_backup.sh
# Jamf Pro Backup & Disaster Recovery Tool
#
# Modes:
#   --mode backup   Export Jamf Pro objects to dated local directories (default)
#   --mode restore  Restore exported objects back to Jamf Pro
#
# Backup Options:
#   --all                    Export everything
#   --policies               Export policies (XML per policy)
#   --profiles               Export macOS config profiles (XML per profile)
#   --static-groups          Export static computer groups + member CSVs
#                            Requires --client-id / --client-secret
#   --smart-groups           Export smart computer groups (JSON per group)
#   --packages               Download .pkg/.dmg files from JCDS
#   --blueprints             Export blueprints (JSON per blueprint)
#   --compliance             Export compliance benchmarks (JSON per benchmark)
#   --computers              Export full computer inventory (single JSON file)
#   --app-installers         Export app installer deployments (JSON per deployment)
#   --scripts                Export scripts (XML per script)
#
# Restore Options:
#   --all                    Restore everything
#   --policies               Restore policies
#   --profiles               Restore macOS config profiles
#   --static-groups          Restore static computer groups
#                            Requires --client-id / --client-secret
#   --smart-groups           Restore smart computer groups
#   --packages               Upload package files to JCDS
#   --blueprints             Restore blueprints
#   --app-installers         Restore app installer deployments
#   --scripts                Restore scripts
#   --source <path>          Specific dated backup folder to restore from
#                            Default: most recent under OUTPUT_BASE
#   --target-url <url>       Jamf Pro URL to restore to
#                            Default: current instance from jamf checkjssconnection
#   --no-prompt              Skip all conflict prompts; overwrite everything
#
# Global Options:
#   --client-id      OAuth client ID for Classic API access (env: JAMF_CLIENT_ID)
#   --client-secret  OAuth client secret for Classic API access (env: JAMF_CLIENT_SECRET)
#   --output-dir <path>      Base output directory (default: ~/Desktop/Jamf_Pro_Backup)
#   --log-file <path>        Log file path (default: <output-dir>/jamf_cli_logs.log)
#   -n, --dry-run            Preview all commands without executing
#   --help                   Show this help message
#
# Requirements:
#   - jamf-cli installed and configured
#     Install: https://github.com/Jamf-Concepts/jamf-cli
#     Setup:   https://github.com/Jamf-Concepts/jamf-cli/wiki/Setup-Guide
#   - jq (bundled in macOS 15+; install via: brew install jq)
#   - Classic API client (required for static groups)
#
# Author: Matt Jerome, Fanatics — Senior Desktop Engineer
# =============================================================================

# bash 3.2 compatible — no mapfile, no ${var^}, no associative arrays

currentYear=$(date +%Y)
currentMonth=$(date +%m)
currentDate=$(date +%d)
currentTime=$(date +%H-%M-%S)
currentUser=$(stat -f "%Su" /dev/console)

OUTPUT_BASE="/Users/${currentUser}/Desktop/Jamf_Pro_Backup"
OUTPUT_DIR=""
scriptLog=""
CLIENT_ID=""
CLIENT_SECRET=""
RESTORE_SOURCE=""
RESTORE_TARGET_URL=""
TARGET_PROFILE=""
TARGET_TENANT_ID=""
NO_PROMPT=false
OVERWRITE_ALL=false
SCRIPT_MODE="backup"
TENANT_ID=""

# =============================================================================
# Logging
# =============================================================================

function updateScriptLog() {
    echo -e "$(date +%Y-%m-%d\ %H:%M:%S) - ${1}" | tee -a "${scriptLog}"
}

function debugLog() {
    [[ "$DRY_RUN" == "true" ]] || return
    echo -e "$(date +%Y-%m-%d\ %H:%M:%S) - [DRY-RUN] ${1}" | tee -a "${scriptLog}" >&2
}

# =============================================================================
# Pre-flight
# =============================================================================

function preflight() {
    if [[ "$SCRIPT_MODE" == "restore" ]]; then
        # In restore mode OUTPUT_DIR is never written to — only RESTORE_DIR is read.
        # Don't create it. If the caller passed --output-dir, note the mismatch.
        if [[ -n "$custom_output_dir" ]]; then
            updateScriptLog "NOTE: --output-dir is ignored in restore mode (use --source to specify the backup path)."
        fi
    else
        if [[ ! -d "$OUTPUT_DIR" ]]; then
            mkdir -p "$OUTPUT_DIR"
        fi
    fi

    if [[ ! -f "$scriptLog" ]]; then
        touch "$scriptLog"
    fi

    if ! command -v jamf-cli &>/dev/null; then
        updateScriptLog "ERROR: jamf-cli not detected."
        updateScriptLog "Opening: https://github.com/Jamf-Concepts/jamf-cli"
        open "https://github.com/Jamf-Concepts/jamf-cli"
        updateScriptLog "Exiting — re-run once jamf-cli is installed."
        exit 1
    fi
    updateScriptLog "jamf-cli detected: $(jamf-cli version 2>/dev/null | head -1)"

    if ! command -v jq &>/dev/null; then
        updateScriptLog "ERROR: jq not found. Install with: brew install jq"
        exit 1
    fi
    updateScriptLog "jq detected: $(jq --version 2>/dev/null)"

    local configList
    configList=$(jamf-cli config list 2>&1)
    if [[ "$configList" == *"No Profiles Configured"* ]] || [[ "$configList" == "[]" ]]; then
        updateScriptLog "ERROR: No jamf-cli profiles configured."
        updateScriptLog "Run: jamf-cli pro setup --url https://your.jamfcloud.com"
        exit 1
    fi
    updateScriptLog "jamf-cli profile(s) detected."

    # Extract tenant ID from config for Platform API calls
    TENANT_ID=$(echo "$configList" | jq -r '.[0]."tenant-id" // ""' 2>/dev/null)
    if [[ -n "$TENANT_ID" ]]; then
        updateScriptLog "Tenant ID: $TENANT_ID"
    fi

    if [[ "$SCRIPT_MODE" == "backup" ]]; then
        updateScriptLog "Output directory: $OUTPUT_DIR"
    fi
}

# =============================================================================
# Shared helpers
# =============================================================================

function sanitize() {
    local name="$1"
    name="${name//\//_}"
    name="${name//:/—}"
    name="${name//\\/_ }"
    name="${name//\"/}"
    name="${name//$'\t'/_ }"
    name="${name:0:200}"
    echo "$name"
}

function ucfirst() {
    local str="$1"
    local first
    first=$(echo "${str:0:1}" | tr '[:lower:]' '[:upper:]')
    echo "${first}${str:1}"
}

# ---------------------------------------------------------------------------
# parseJsonIdName <json_string>
# Prints "id<TAB>name" lines from a jamf-cli JSON list response.
# ---------------------------------------------------------------------------
function parseJsonIdName() {
    local json="$1"
    local result
    result=$(echo "$json" | jq -r '
        (if type == "array" then . else .results // .items // . end) |
        .[] | [(.id | tostring), (.name // "")] | @tsv
    ' 2>/dev/null | grep -v $'^\t$')
    debugLog "parseJsonIdName: $(echo "$result" | grep -c .) entries extracted"
    echo "$result"
}

# ---------------------------------------------------------------------------
# getJamfURL
# Extracts the Jamf Pro base URL. Uses RESTORE_TARGET_URL if set,
# otherwise falls back to jamf checkjssconnection.
# Sets global JAMF_URL on success.
# ---------------------------------------------------------------------------
JAMF_URL=""

function getJamfURL() {
    [[ -n "$JAMF_URL" ]] && return 0

    if [[ -n "$RESTORE_TARGET_URL" ]]; then
        JAMF_URL="$RESTORE_TARGET_URL"
        updateScriptLog "  Jamf URL (target): $JAMF_URL"
        return 0
    fi

    local raw
    raw=$(jamf checkjssconnection 2>/dev/null)
    JAMF_URL=$(echo "$raw" | grep -o 'https://[^/]*' | head -1)

    if [[ -z "$JAMF_URL" ]]; then
        updateScriptLog "  ERROR: Could not determine Jamf URL from jamf checkjssconnection."
        updateScriptLog "  Output was: $raw"
        return 1
    fi

    updateScriptLog "  Jamf URL: $JAMF_URL"
    return 0
}

# ---------------------------------------------------------------------------
# getJamfToken
# Obtains a Bearer token for Classic API via OAuth2 client credentials.
# Sets global JAMF_TOKEN on success. Cached within the same run.
# ---------------------------------------------------------------------------
JAMF_TOKEN=""

function getJamfToken() {
    [[ -n "$JAMF_TOKEN" ]] && return 0

    if [[ -z "$CLIENT_ID" ]] || [[ -z "$CLIENT_SECRET" ]]; then
        updateScriptLog "  ERROR: Classic API credentials not provided."
        updateScriptLog "  Re-run with: --client-id <id> --client-secret <secret>"
        updateScriptLog "  Or set env vars: JAMF_CLIENT_ID / JAMF_CLIENT_SECRET"
        updateScriptLog "  Create an API client in Jamf Pro: Settings → System → API Roles and Clients"
        return 1
    fi

    updateScriptLog "  Obtaining Classic API token via jamf-cli..."

    local auth_json
    auth_json=$(JAMF_CLIENT_ID="$CLIENT_ID" JAMF_CLIENT_SECRET="$CLIENT_SECRET" \
        jamf-cli pro auth token 2>/dev/null)
    JAMF_TOKEN=$(echo "$auth_json" | jq -r '.token // .access_token // ""' 2>/dev/null)

    if [[ -z "$JAMF_TOKEN" ]]; then
        updateScriptLog "  ERROR: Could not obtain Classic API token via jamf-cli."
        return 1
    fi

    updateScriptLog "  Classic API token obtained."
    return 0
}

# ---------------------------------------------------------------------------
# getPlatformToken
# Obtains a Platform API Bearer token via jamf-cli for Pro/Platform API calls.
# Sets global PLATFORM_TOKEN on success. Cached within the same run.
# ---------------------------------------------------------------------------
PLATFORM_TOKEN=""

function getPlatformToken() {
    [[ -n "$PLATFORM_TOKEN" ]] && return 0
    local auth_json
    auth_json=$(jamf-cli pro auth token 2>/dev/null)
    PLATFORM_TOKEN=$(echo "$auth_json" | jq -r '.token // ""' 2>/dev/null)
    if [[ -z "$PLATFORM_TOKEN" ]]; then
        updateScriptLog "  ERROR: Could not obtain Platform API token via jamf-cli."
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# jamf-cli [args...]
# Wrapper around jamf-cli that injects --profile <TARGET_PROFILE> when set.
# Use for all jamf-cli calls inside restore functions so they hit the
# target instance rather than the default configured profile.
# ---------------------------------------------------------------------------
function jamf-cli() {
    if [[ -n "$TARGET_PROFILE" ]]; then
        jamf-cli --profile "$TARGET_PROFILE" "$@"
    else
        jamf-cli "$@"
    fi
}

# ---------------------------------------------------------------------------
# resolveTargetProfile
# When --target-profile is set, extracts the Jamf URL and Tenant ID
# from that profile's config and populates RESTORE_TARGET_URL and
# TARGET_TENANT_ID (unless already explicitly provided by the caller).
# ---------------------------------------------------------------------------
function resolveTargetProfile() {
    [[ -z "$TARGET_PROFILE" ]] && return 0

    updateScriptLog "  Resolving target profile: $TARGET_PROFILE"

    local config
    config=$(jamf-cli config list 2>&1)

    # Derive target URL from profile unless --target-url was explicitly passed
    if [[ -z "$RESTORE_TARGET_URL" ]]; then
        RESTORE_TARGET_URL=$(echo "$config" | jq -r --arg p "$TARGET_PROFILE" \
            '.[] | select(.name == $p) | .url // ""' 2>/dev/null)
        if [[ -n "$RESTORE_TARGET_URL" ]]; then
            updateScriptLog "  Target URL  : $RESTORE_TARGET_URL (from profile '$TARGET_PROFILE')"
        else
            updateScriptLog "  WARNING: Could not derive URL from profile '$TARGET_PROFILE' — Classic API calls may fail."
            updateScriptLog "           Pass --target-url <url> to override."
        fi
    fi

    # Derive tenant ID from profile unless --target-tenant-id was explicitly passed
    if [[ -z "$TARGET_TENANT_ID" ]]; then
        TARGET_TENANT_ID=$(echo "$config" | jq -r --arg p "$TARGET_PROFILE" \
            '.[] | select(.name == $p) | ."tenant-id" // ""' 2>/dev/null)
        if [[ -n "$TARGET_TENANT_ID" ]]; then
            updateScriptLog "  Target Tenant ID: $TARGET_TENANT_ID (from profile '$TARGET_PROFILE')"
        else
            updateScriptLog "  WARNING: Could not derive Tenant ID from profile '$TARGET_PROFILE' — smart group restore may fail."
            updateScriptLog "           Pass --target-tenant-id <id> to override."
        fi
    fi
}

# ---------------------------------------------------------------------------
# restorePrompt <object_type> <name>
# Prompts the user how to handle a conflict.
# Sets RESTORE_ACTION: "overwrite", "skip", or "quit"
# Respects NO_PROMPT and OVERWRITE_ALL globals.
# ---------------------------------------------------------------------------
function restorePrompt() {
    local obj_type="$1"
    local obj_name="$2"

    if [[ "$NO_PROMPT" == "true" ]] || [[ "$OVERWRITE_ALL" == "true" ]]; then
        RESTORE_ACTION="overwrite"
        return
    fi

    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────┐"
    echo "  │ CONFLICT: $obj_type '$obj_name' already exists."
    echo "  │ [O]verwrite  [S]kip  [A]ll (overwrite all)  [Q]uit   [O]: "
    echo -n "  └─ Choice: "
    local choice
    read -r choice
    choice="${choice:-O}"
    choice=$(echo "$choice" | tr '[:lower:]' '[:upper:]')

    case "$choice" in
        O) RESTORE_ACTION="overwrite" ;;
        S) RESTORE_ACTION="skip" ;;
        A) OVERWRITE_ALL=true; RESTORE_ACTION="overwrite" ;;
        Q) updateScriptLog "Restore aborted by user."; exit 0 ;;
        *) updateScriptLog "  Invalid choice — defaulting to Overwrite."; RESTORE_ACTION="overwrite" ;;
    esac
}

# ---------------------------------------------------------------------------
# classicApiExists <endpoint_path> <name_field> <name_value>
# Checks if a named object exists via Classic API GET.
# Returns 0 (exists) with EXISTING_ID set, or 1 (not found).
# ---------------------------------------------------------------------------
EXISTING_ID=""

function classicApiExists() {
    local endpoint="$1"   # e.g. /JSSResource/policies/name/
    local name="$2"

    if ! getJamfURL || ! getJamfToken; then
        return 1
    fi

    local encoded_name
    encoded_name=$(printf '%s' "$name" | jq -sRr @uri 2>/dev/null || printf '%s' "$name")

    local response http_code tmpbody
    tmpbody=$(mktemp)
    http_code=$(curl -s -o "$tmpbody" -w "%{http_code}" -X GET \
        "${JAMF_URL}${endpoint}${encoded_name}" \
        -H "accept: application/xml" \
        -H "Authorization: Bearer ${JAMF_TOKEN}" \
        2>>"${scriptLog}")
    response=$(cat "$tmpbody"); rm -f "$tmpbody"

    if [[ "$http_code" == "200" ]]; then
        # Extract top-level id from response
        EXISTING_ID=$(echo "$response" | sed 's/></>\
</g' | awk '
            NR <= 5 {
                line = $0
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                if (line ~ /<id>[0-9]+<\/id>/) {
                    gsub(/<\/?id>/, "", line); print line; exit
                }
            }')
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# xmlExtractMembers <xml_string> <group_id> <group_name>
# Parses Classic API computer group XML and prints CSV rows to stdout.
# ---------------------------------------------------------------------------
function xmlExtractMembers() {
    local xml="$1"
    local gid="$2"
    local gname="$3"

    local safe_gname="${gname//\"/\"\"}"

    echo "$xml" | sed 's/></>\
</g' | awk -v gid="$gid" -v gname="$safe_gname" '
        /<computer>/   { in_computer=1; id=""; cname=""; serial="" }
        /<\/computer>/ {
            if (in_computer && id != "")
                printf "\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"\n", gid, gname, id, cname, serial
            in_computer=0
        }
        in_computer {
            line = $0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line ~ /<id>[0-9]+<\/id>/) {
                gsub(/<\/?id>/, "", line); id = line
            }
            if (line ~ /<name>.*<\/name>/) {
                gsub(/^<name>/, "", line); gsub(/<\/name>$/, "", line)
                gsub(/"/, "\"\"", line); cname = line
            }
            if (line ~ /<serial_number>.*<\/serial_number>/) {
                gsub(/^<serial_number>/, "", line); gsub(/<\/serial_number>$/, "", line)
                serial = line
            }
        }
    '
}

# =============================================================================
# findRestoreSource
# Resolves the backup folder to restore from.
# Uses RESTORE_SOURCE if set, otherwise finds the most recent dated subfolder.
# Sets RESTORE_DIR on success.
# =============================================================================
RESTORE_DIR=""

function findRestoreSource() {
    if [[ -n "$RESTORE_SOURCE" ]]; then
        if [[ ! -d "$RESTORE_SOURCE" ]]; then
            updateScriptLog "ERROR: --source directory does not exist: $RESTORE_SOURCE"
            exit 1
        fi
        RESTORE_DIR="$RESTORE_SOURCE"
        updateScriptLog "Restore source: $RESTORE_DIR"
        return 0
    fi

    # Find most recent YYYY_MM_DD subfolder under OUTPUT_BASE
    local most_recent
    most_recent=$(ls -1d "${OUTPUT_BASE}"/[0-9][0-9][0-9][0-9]_[0-9][0-9]_[0-9][0-9] 2>/dev/null | sort -r | head -1)

    if [[ -z "$most_recent" ]]; then
        updateScriptLog "ERROR: No dated backup folders found under $OUTPUT_BASE"
        updateScriptLog "Run a backup first, or specify --source <path>"
        exit 1
    fi

    RESTORE_DIR="$most_recent"
    updateScriptLog "Restore source (most recent): $RESTORE_DIR"
    return 0
}

# =============================================================================
# BACKUP FUNCTIONS
# =============================================================================

# =============================================================================
# Policies backup  (Classic API)
# =============================================================================

function policies() {
    updateScriptLog "--- Exporting policies ---"
    local dir="${OUTPUT_DIR}/policies"
    mkdir -p "$dir"
    local success=0 fail=0

    local list_json
    list_json=$(jamf-cli pro classic-policies list -o json 2>/dev/null)
    updateScriptLog "  List response: $(echo "$list_json" | wc -c | tr -d ' ') bytes"

    local tmpfile
    tmpfile=$(mktemp /tmp/jamf_policies.XXXXXX)
    parseJsonIdName "$list_json" > "$tmpfile"
    updateScriptLog "  Found $(wc -l < "$tmpfile" | tr -d ' ') policies."

    while IFS=$'\t' read -r policy_id policy_name; do
        [[ -z "$policy_id" ]] && continue
        local safe_name
        safe_name=$(sanitize "$policy_name")
        updateScriptLog "  Policy: $policy_name (ID: $policy_id)"
        if [[ "$DRY_RUN" == "true" ]]; then
            updateScriptLog "  [DRY-RUN] jamf-cli pro classic-policies get $policy_id -o xml > ${dir}/${safe_name}.xml"
            (( success++ ))
        elif jamf-cli pro classic-policies get "$policy_id" -o xml \
               > "${dir}/${safe_name}.xml" 2>>"${scriptLog}" && [[ -s "${dir}/${safe_name}.xml" ]]; then
            (( success++ ))
        else
            updateScriptLog "  WARNING: Failed to export policy ID $policy_id"
            rm -f "${dir}/${safe_name}.xml"
            (( fail++ ))
        fi
    done < "$tmpfile"

    rm -f "$tmpfile"
    updateScriptLog "Policies complete: $success exported, $fail failed → $dir"
}

# =============================================================================
# Profiles backup  (Classic API)
# =============================================================================

function profiles() {
    updateScriptLog "--- Exporting macOS configuration profiles ---"
    local dir="${OUTPUT_DIR}/profiles"
    mkdir -p "$dir"
    local success=0 fail=0

    local list_json
    list_json=$(jamf-cli pro classic-macos-config-profiles list -o json 2>/dev/null)
    updateScriptLog "  List response: $(echo "$list_json" | wc -c | tr -d ' ') bytes"

    local tmpfile
    tmpfile=$(mktemp /tmp/jamf_profiles.XXXXXX)
    parseJsonIdName "$list_json" > "$tmpfile"
    updateScriptLog "  Found $(wc -l < "$tmpfile" | tr -d ' ') profiles."

    while IFS=$'\t' read -r profile_id profile_name; do
        [[ -z "$profile_id" ]] && continue
        local safe_name
        safe_name=$(sanitize "$profile_name")
        updateScriptLog "  Profile: $profile_name (ID: $profile_id)"
        if [[ "$DRY_RUN" == "true" ]]; then
            updateScriptLog "  [DRY-RUN] jamf-cli pro classic-macos-config-profiles get $profile_id -o xml > ${dir}/${safe_name}.xml"
            (( success++ ))
        elif jamf-cli pro classic-macos-config-profiles get "$profile_id" -o xml \
               > "${dir}/${safe_name}.xml" 2>>"${scriptLog}" && [[ -s "${dir}/${safe_name}.xml" ]]; then
            (( success++ ))
        else
            updateScriptLog "  WARNING: Failed to export profile ID $profile_id"
            rm -f "${dir}/${safe_name}.xml"
            (( fail++ ))
        fi
    done < "$tmpfile"

    rm -f "$tmpfile"
    updateScriptLog "Profiles complete: $success exported, $fail failed → $dir"
}

# =============================================================================
# Computer Groups backup
# =============================================================================

function computerGroups() {
    local mode="$1"
    local mode_label
    mode_label=$(ucfirst "$mode")
    local dir="${OUTPUT_DIR}/${mode}_groups"
    mkdir -p "$dir"
    local success=0 fail=0

    updateScriptLog "--- Exporting ${mode} computer groups ---"

    if [[ "$mode" == "static" ]]; then

        if [[ -z "$CLIENT_ID" ]] || [[ -z "$CLIENT_SECRET" ]]; then
            updateScriptLog "  WARNING: --client-id and --client-secret are required for static groups."
            updateScriptLog "  Skipping static groups."
            return 1
        fi

        if ! getJamfURL || ! getJamfToken; then
            updateScriptLog "  ERROR: Cannot fetch auth — skipping static groups."
            return 1
        fi

        local all_groups_xml http_code tmpbody
        tmpbody=$(mktemp)
        http_code=$(curl -s -o "$tmpbody" -w "%{http_code}" -X GET \
            "${JAMF_URL}/JSSResource/computergroups" \
            -H "accept: application/xml" \
            -H "Authorization: Bearer ${JAMF_TOKEN}" \
            2>>"${scriptLog}")
        all_groups_xml=$(cat "$tmpbody"); rm -f "$tmpbody"
        updateScriptLog "  /JSSResource/computergroups HTTP status: ${http_code}"

        if [[ -z "$all_groups_xml" ]] || [[ "$http_code" != "200" ]]; then
            updateScriptLog "  ERROR: Bad response from /JSSResource/computergroups (HTTP ${http_code})"
            return 1
        fi

        local id_name_tmp
        id_name_tmp=$(mktemp /tmp/jamf_grp_ids.XXXXXX)

        echo "$all_groups_xml" | sed 's/></>\
</g' | awk '
            /<computer_group>/   { in_group=1; id=""; gname=""; smart="" }
            /<\/computer_group>/ {
                if (in_group && smart == "false" && id != "")
                    printf "%s\t%s\n", id, gname
                in_group=0
            }
            in_group {
                line = $0
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                if (line ~ /<id>[0-9]+<\/id>/) {
                    gsub(/<\/?id>/, "", line); id = line
                }
                if (line ~ /<name>.*<\/name>/) {
                    gsub(/^<name>/, "", line); gsub(/<\/name>$/, "", line); gname = line
                }
                if (line ~ /<is_smart>.*<\/is_smart>/) {
                    gsub(/^<is_smart>/, "", line); gsub(/<\/is_smart>$/, "", line); smart = line
                }
            }
        ' > "$id_name_tmp"

        local count
        count=$(wc -l < "$id_name_tmp" | tr -d ' ')
        if [[ "$count" -eq 0 ]]; then
            updateScriptLog "  No static computer groups found."
            rm -f "$id_name_tmp"; return
        fi
        updateScriptLog "  Found $count static computer groups."

        local members_csv="${dir}/_all_members.csv"
        echo "group_id,group_name,computer_id,computer_name,serial_number" > "$members_csv"

        while IFS=$'\t' read -r group_id group_name; do
            [[ -z "$group_id" ]] && continue
            local safe_name
            safe_name=$(sanitize "$group_name")
            updateScriptLog "  Static group: $group_name (ID: $group_id)"

            if [[ "$DRY_RUN" == "true" ]]; then
                updateScriptLog "  [DRY-RUN] curl GET ${JAMF_URL}/JSSResource/computergroups/id/${group_id}"
                (( success++ )); continue
            fi

            local group_xml group_http_code tmpbody
            tmpbody=$(mktemp)
            group_http_code=$(curl -s -o "$tmpbody" -w "%{http_code}" -X GET \
                "${JAMF_URL}/JSSResource/computergroups/id/${group_id}" \
                -H "accept: application/xml" \
                -H "Authorization: Bearer ${JAMF_TOKEN}" \
                2>>"${scriptLog}")
            group_xml=$(cat "$tmpbody"); rm -f "$tmpbody"

            if [[ -z "$group_xml" ]] || [[ "$group_http_code" != "200" ]]; then
                updateScriptLog "  WARNING: Bad response for group $group_id (HTTP ${group_http_code})"
                (( fail++ )); continue
            fi

            echo "$group_xml" > "${dir}/${safe_name}.xml"
            (( success++ ))

            local group_csv="${dir}/${safe_name}_members.csv"
            echo "group_id,group_name,computer_id,computer_name,serial_number" > "$group_csv"
            xmlExtractMembers "$group_xml" "$group_id" "$group_name" >> "$group_csv"

            local member_count
            member_count=$(( $(wc -l < "$group_csv" | tr -d ' ') - 1 ))
            updateScriptLog "    → $member_count members → ${safe_name}_members.csv"
            tail -n +2 "$group_csv" >> "$members_csv"

        done < "$id_name_tmp"

        local total_members
        total_members=$(( $(wc -l < "$members_csv" | tr -d ' ') - 1 ))
        updateScriptLog "  Combined members CSV: $total_members rows → $members_csv"
        rm -f "$id_name_tmp"

    else
        # Smart groups
        local list_json
        list_json=$(jamf-cli pro smart-computer-groups list -o json 2>/dev/null)
        local raw_bytes
        raw_bytes=$(echo "$list_json" | wc -c | tr -d ' ')
        updateScriptLog "  List response: ${raw_bytes} bytes"

        if [[ "$raw_bytes" -lt 5 ]]; then
            updateScriptLog "  ERROR: Empty response from jamf-cli pro smart-computer-groups list"
            return 1
        fi

        local id_name_tmp
        id_name_tmp=$(mktemp /tmp/jamf_grp_ids.XXXXXX)
        parseJsonIdName "$list_json" > "$id_name_tmp"

        local count
        count=$(wc -l < "$id_name_tmp" | tr -d ' ')
        if [[ "$count" -eq 0 ]]; then
            updateScriptLog "  No smart groups found."
            rm -f "$id_name_tmp"; return
        fi
        updateScriptLog "  Found $count smart computer groups."

        while IFS=$'\t' read -r group_id group_name; do
            [[ -z "$group_id" ]] && continue
            local safe_name
            safe_name=$(sanitize "$group_name")
            updateScriptLog "  Smart group: $group_name (ID: $group_id)"

            if [[ "$DRY_RUN" == "true" ]]; then
                updateScriptLog "  [DRY-RUN] jamf-cli pro smart-computer-groups get $group_id -o json > ${dir}/${safe_name}.json"
                (( success++ )); continue
            fi

            local group_json
            group_json=$(jamf-cli pro smart-computer-groups get "$group_id" -o json 2>/dev/null)
            if [[ -z "$group_json" ]]; then
                updateScriptLog "  WARNING: Empty response for group $group_id"
                (( fail++ )); continue
            fi
            echo "$group_json" > "${dir}/${safe_name}.json"
            (( success++ ))

        done < "$id_name_tmp"
        rm -f "$id_name_tmp"
    fi

    updateScriptLog "${mode_label} groups complete: $success exported, $fail failed → $dir"
}

function staticGroups() { computerGroups "static"; }
function smartGroups()  { computerGroups "smart";  }

# =============================================================================
# Packages backup
# =============================================================================

function packages() {
    updateScriptLog "--- Downloading package files from JCDS ---"
    local dir="${OUTPUT_DIR}/packages"
    mkdir -p "$dir"
    local success=0 fail=0 skipped=0

    local jcds_json
    jcds_json=$(jamf-cli pro jcds list -o json 2>/dev/null)

    if [[ -z "$jcds_json" ]]; then
        updateScriptLog "ERROR: 'jamf-cli pro jcds list' returned no output."
        return 1
    fi

    local tmpfile
    tmpfile=$(mktemp /tmp/jamf_jcds_names.XXXXXX)
    echo "$jcds_json" | jq -r '.[].fileName // empty' 2>/dev/null > "$tmpfile"

    local total
    total=$(wc -l < "$tmpfile" | tr -d ' ')
    updateScriptLog "  Found $total files in JCDS."

    if [[ "$total" -eq 0 ]]; then
        updateScriptLog "  Raw snippet: $(echo "$jcds_json" | head -c 400)"
        rm -f "$tmpfile"; return
    fi

    while IFS= read -r pkg_filename; do
        [[ -z "$pkg_filename" ]] && continue
        updateScriptLog "  Downloading: $pkg_filename"
        local dest="${dir}/${pkg_filename}"

        if [[ -f "$dest" ]]; then
            updateScriptLog "  Already exists, skipping."
            (( skipped++ )); continue
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            updateScriptLog "  [DRY-RUN] jamf-cli pro jcds download \"$pkg_filename\" --output \"$dest\""
            (( success++ ))
        elif jamf-cli pro jcds download "$pkg_filename" --output "$dest" 2>>"${scriptLog}"; then
            local filesize
            filesize=$(du -sh "$dest" 2>/dev/null | cut -f1)
            updateScriptLog "  Done: $pkg_filename ($filesize)"
            (( success++ ))
        else
            updateScriptLog "  WARNING: Download failed for $pkg_filename"
            (( fail++ ))
        fi
    done < "$tmpfile"

    rm -f "$tmpfile"
    updateScriptLog "Packages complete: $success downloaded, $skipped skipped, $fail failed → $dir"
}

# =============================================================================
# Blueprints backup
# =============================================================================

function blueprints() {
    updateScriptLog "--- Exporting blueprints ---"
    local dir="${OUTPUT_DIR}/blueprints"
    mkdir -p "$dir"
    local success=0 fail=0

    local list_json
    list_json=$(jamf-cli pro blueprints list -o json 2>/dev/null)

    local tmpfile
    tmpfile=$(mktemp /tmp/jamf_blueprints.XXXXXX)
    parseJsonIdName "$list_json" > "$tmpfile"

    local count
    count=$(wc -l < "$tmpfile" | tr -d ' ')
    if [[ "$count" -eq 0 ]]; then
        updateScriptLog "  No blueprints found. (Requires platform auth-method profile)"
        rm -f "$tmpfile"; return
    fi
    updateScriptLog "  Found $count blueprints."

    while IFS=$'\t' read -r bp_id bp_name; do
        [[ -z "$bp_id" ]] && continue
        updateScriptLog "  Blueprint: $bp_name (ID: $bp_id)"

        if [[ "$DRY_RUN" == "true" ]]; then
            local safe_name
            safe_name=$(sanitize "$bp_name")
            [[ -z "$safe_name" ]] && safe_name="$bp_id"
            updateScriptLog "  [DRY-RUN] jamf-cli pro blueprints get $bp_id -o json > ${dir}/${safe_name}.json"
            (( success++ ))
            continue
        fi

        # Fetch full record and derive filename from the get response
        local bp_json
        bp_json=$(jamf-cli pro blueprints get "$bp_id" -o json 2>>"${scriptLog}")
        if [[ -z "$bp_json" ]]; then
            updateScriptLog "  WARNING: Empty response for blueprint ID $bp_id"
            (( fail++ ))
            continue
        fi

        local bp_label
        bp_label=$(echo "$bp_json" | jq -r '.name // ""' 2>/dev/null)
        local safe_name
        safe_name=$(sanitize "$bp_label")
        # Append short ID suffix to ensure uniqueness for unnamed/duplicate-named blueprints
        [[ -z "$safe_name" ]] && safe_name="${bp_id}"

        local out_file="${dir}/${safe_name}.json"
        if echo "$bp_json" > "$out_file" && [[ -s "$out_file" ]]; then
            (( success++ ))
        else
            updateScriptLog "  WARNING: Failed to write blueprint $bp_id"
            rm -f "$out_file"
            (( fail++ ))
        fi
    done < "$tmpfile"

    rm -f "$tmpfile"
    updateScriptLog "Blueprints complete: $success exported, $fail failed → $dir"
}

# =============================================================================
# Compliance backup
# =============================================================================

function compliance() {
    updateScriptLog "--- Exporting compliance benchmarks ---"

    local dir="${OUTPUT_DIR}/compliance"
    mkdir -p "$dir"
    local success=0 fail=0

    local list_json
    list_json=$(jamf-cli pro compliance-benchmarks list -o json 2>/dev/null)

    if [[ -z "$list_json" ]]; then
        updateScriptLog "  No response from compliance-benchmarks list."
        updateScriptLog "  (Requires platform auth-method profile + Jamf Security Cloud license)"
        return
    fi

    local tmpfile
    tmpfile=$(mktemp /tmp/jamf_compliance.XXXXXX)

    echo "$list_json" | jq -r '
        (if type == "array" then . else .results // .items // .benchmarks // . end) |
        .[] | (.id // .benchmarkId // ._id) // "" | select(. != "")
    ' 2>/dev/null > "$tmpfile"

    local count
    count=$(wc -l < "$tmpfile" | tr -d ' ')
    if [[ "$count" -eq 0 ]]; then
        updateScriptLog "  No compliance benchmarks found."
        rm -f "$tmpfile"; return
    fi
    updateScriptLog "  Found $count benchmarks."

    while IFS= read -r bench_id; do
        [[ -z "$bench_id" ]] && continue

        if [[ "$DRY_RUN" == "true" ]]; then
            updateScriptLog "  [DRY-RUN] jamf-cli pro compliance-benchmarks get $bench_id -o json"
            (( success++ )); continue
        fi

        local bench_json
        bench_json=$(jamf-cli pro compliance-benchmarks get "$bench_id" -o json 2>>"${scriptLog}")

        if [[ -z "$bench_json" ]]; then
            updateScriptLog "  WARNING: Empty response for benchmark ID $bench_id"
            (( fail++ )); continue
        fi

        local bench_name
        bench_name=$(echo "$bench_json" | jq -r '(.title // .baselineId // .name // "") | gsub("^\\s+|\\s+$"; "") | .[0:80]' 2>/dev/null)

        local safe_name
        safe_name=$(sanitize "$bench_name")
        [[ -z "$safe_name" ]] && safe_name="$bench_id"
        updateScriptLog "  Benchmark: $bench_name (ID: $bench_id)"

        local out_file="${dir}/${safe_name}.json"
        if echo "$bench_json" > "$out_file" && [[ -s "$out_file" ]]; then
            (( success++ ))
        else
            updateScriptLog "  WARNING: Failed to write benchmark ID $bench_id"
            rm -f "$out_file"; (( fail++ ))
        fi
    done < "$tmpfile"

    rm -f "$tmpfile"
    updateScriptLog "Compliance complete: $success exported, $fail failed → $dir"
}

# =============================================================================
# Computers backup
# =============================================================================

function computers() {
    updateScriptLog "--- Exporting computers ---"
    local dir="${OUTPUT_DIR}/computers"
    mkdir -p "$dir"

    local list_json
    list_json=$(jamf-cli pro computers list -o json 2>/dev/null)

    if [[ -z "$list_json" ]]; then
        updateScriptLog "  ERROR: No response from jamf-cli pro computers list"
        return 1
    fi

    local byte_count
    byte_count=$(echo "$list_json" | wc -c | tr -d ' ')
    updateScriptLog "  Response: ${byte_count} bytes"

    if [[ "$DRY_RUN" == "true" ]]; then
        updateScriptLog "  [DRY-RUN] would write computers.json (${byte_count} bytes) → $dir"
        return 0
    fi

    local out_file="${dir}/computers.json"
    if echo "$list_json" > "$out_file" && [[ -s "$out_file" ]]; then
        updateScriptLog "Computers complete: computers.json → $dir"
    else
        updateScriptLog "  ERROR: Failed to write computers.json"
        rm -f "$out_file"; return 1
    fi
}

# =============================================================================
# App Installer Deployments backup
# =============================================================================

function appInstallerDeployments() {
    updateScriptLog "--- Exporting app installer deployments ---"
    local dir="${OUTPUT_DIR}/app_installer_deployments"
    mkdir -p "$dir"
    local success=0 fail=0

    local list_json
    list_json=$(jamf-cli pro app-installer-deployments list -o json 2>/dev/null)

    if [[ -z "$list_json" ]]; then
        updateScriptLog "  ERROR: No response from jamf-cli pro app-installer-deployments list"
        return 1
    fi

    echo "$list_json" > "${dir}/_all_deployments.json"

    local tmpfile
    tmpfile=$(mktemp /tmp/jamf_appinstaller.XXXXXX)
    parseJsonIdName "$list_json" > "$tmpfile"

    local count
    count=$(wc -l < "$tmpfile" | tr -d ' ')
    if [[ "$count" -eq 0 ]]; then
        updateScriptLog "  No app installer deployments found."
        rm -f "$tmpfile"; return
    fi
    updateScriptLog "  Found $count app installer deployments."

    while IFS=$'\t' read -r app_id app_name; do
        [[ -z "$app_id" ]] && continue
        local safe_name
        safe_name=$(sanitize "$app_name")
        [[ -z "$safe_name" ]] && safe_name="$app_id"
        # Append ID suffix if a file with this name already exists (duplicate app names)
        [[ -f "${dir}/${safe_name}.json" ]] && safe_name="${safe_name}_${app_id}"
        updateScriptLog "  App: $app_name (ID: $app_id)"

        if [[ "$DRY_RUN" == "true" ]]; then
            updateScriptLog "  [DRY-RUN] jamf-cli pro app-installer-deployments get $app_id -o json > ${dir}/${safe_name}.json"
            (( success++ )); continue
        fi

        local out_file="${dir}/${safe_name}.json"
        if jamf-cli pro app-installer-deployments get "$app_id" -o json \
               > "$out_file" 2>>"${scriptLog}" && [[ -s "$out_file" ]]; then
            (( success++ ))
        else
            updateScriptLog "  WARNING: Failed to export deployment ID $app_id"
            rm -f "$out_file"; (( fail++ ))
        fi
    done < "$tmpfile"

    rm -f "$tmpfile"
    updateScriptLog "App installer deployments complete: $success exported, $fail failed → $dir"
}

# =============================================================================
# RESTORE FUNCTIONS
# =============================================================================

# =============================================================================
# restorePolicies
# Restores policies from XML files via Classic API.
# POST /JSSResource/policies/id/0  (create)
# PUT  /JSSResource/policies/id/{id} (update)
# =============================================================================

function restorePolicies() {
    updateScriptLog "--- Restoring policies ---"
    local dir="${RESTORE_DIR}/policies"

    if [[ ! -d "$dir" ]]; then
        updateScriptLog "  No policies folder found in backup: $dir"
        return
    fi

    if ! getJamfURL || ! getJamfToken; then
        updateScriptLog "  ERROR: --client-id and --client-secret are required to restore policies."
        return 1
    fi

    local success=0 fail=0 skipped=0
    local xml_file

    for xml_file in "${dir}"/*.xml; do
        [[ -f "$xml_file" ]] || continue
        local filename
        filename=$(basename "$xml_file")

        # Extract policy name from XML
        local policy_name
        policy_name=$(sed 's/></>\
</g' "$xml_file" | awk '
            /<general>/ { in_general=1 }
            /<\/general>/ { in_general=0 }
            in_general && /<name>.*<\/name>/ {
                gsub(/^[[:space:]]*<name>/, ""); gsub(/<\/name>.*/, ""); print; exit
            }')

        updateScriptLog "  Policy: $policy_name ($filename)"

        if [[ "$DRY_RUN" == "true" ]]; then
            updateScriptLog "  [DRY-RUN] would restore policy '$policy_name'"
            (( success++ )); continue
        fi

        # Check if policy exists by name
        local endpoint="/JSSResource/policies/name/"
        EXISTING_ID=""
        if classicApiExists "$endpoint" "$policy_name"; then
            restorePrompt "Policy" "$policy_name"
            if [[ "$RESTORE_ACTION" == "skip" ]]; then
                updateScriptLog "  Skipped: $policy_name"
                (( skipped++ )); continue
            fi
            # Update existing
            local http_code
            http_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
                "${JAMF_URL}/JSSResource/policies/id/${EXISTING_ID}" \
                -H "Content-Type: application/xml" \
                -H "Authorization: Bearer ${JAMF_TOKEN}" \
                --data-binary "@${xml_file}" 2>>"${scriptLog}")
            if [[ "$http_code" =~ ^2 ]]; then
                updateScriptLog "  Updated: $policy_name (ID: $EXISTING_ID)"
                (( success++ ))
            else
                updateScriptLog "  WARNING: Update failed for '$policy_name' (HTTP $http_code)"
                (( fail++ ))
            fi
        else
            # Create new
            local http_code
            http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
                "${JAMF_URL}/JSSResource/policies/id/0" \
                -H "Content-Type: application/xml" \
                -H "Authorization: Bearer ${JAMF_TOKEN}" \
                --data-binary "@${xml_file}" 2>>"${scriptLog}")
            if [[ "$http_code" =~ ^2 ]]; then
                updateScriptLog "  Created: $policy_name"
                (( success++ ))
            elif [[ "$http_code" == "409" ]]; then
                # 409 = already exists but classicApiExists missed it (name encoding,
                # trailing whitespace, etc.). Re-look up the ID and fall back to PUT.
                updateScriptLog "  409 conflict on POST — falling back to update for '$policy_name'"
                EXISTING_ID=""
                if classicApiExists "$endpoint" "$policy_name"; then
                    local put_code
                    put_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
                        "${JAMF_URL}/JSSResource/policies/id/${EXISTING_ID}" \
                        -H "Content-Type: application/xml" \
                        -H "Authorization: Bearer ${JAMF_TOKEN}" \
                        --data-binary "@${xml_file}" 2>>"${scriptLog}")
                    if [[ "$put_code" =~ ^2 ]]; then
                        updateScriptLog "  Updated (409 fallback): $policy_name (ID: $EXISTING_ID)"
                        (( success++ ))
                    else
                        updateScriptLog "  WARNING: 409 fallback PUT failed for '$policy_name' (HTTP $put_code)"
                        (( fail++ ))
                    fi
                else
                    updateScriptLog "  WARNING: 409 but could not resolve existing ID for '$policy_name'"
                    (( fail++ ))
                fi
            else
                updateScriptLog "  WARNING: Create failed for '$policy_name' (HTTP $http_code)"
                (( fail++ ))
            fi
        fi
    done

    updateScriptLog "Policies restore complete: $success restored, $skipped skipped, $fail failed"
}

# =============================================================================
# restoreProfiles
# Restores macOS config profiles from XML via Classic API.
# =============================================================================

function restoreProfiles() {
    updateScriptLog "--- Restoring macOS config profiles ---"
    local dir="${RESTORE_DIR}/profiles"

    if [[ ! -d "$dir" ]]; then
        updateScriptLog "  No profiles folder found in backup: $dir"
        return
    fi

    if ! getJamfURL || ! getJamfToken; then
        updateScriptLog "  ERROR: --client-id and --client-secret are required to restore profiles."
        return 1
    fi

    local success=0 fail=0 skipped=0
    local xml_file

    for xml_file in "${dir}"/*.xml; do
        [[ -f "$xml_file" ]] || continue
        local filename
        filename=$(basename "$xml_file")

        local profile_name
        profile_name=$(sed 's/></>\
</g' "$xml_file" | awk '
            /<general>/ { in_general=1 }
            /<\/general>/ { in_general=0 }
            in_general && /<name>.*<\/name>/ {
                gsub(/^[[:space:]]*<name>/, ""); gsub(/<\/name>.*/, ""); print; exit
            }')

        updateScriptLog "  Profile: $profile_name ($filename)"

        if [[ "$DRY_RUN" == "true" ]]; then
            updateScriptLog "  [DRY-RUN] would restore profile '$profile_name'"
            (( success++ )); continue
        fi

        EXISTING_ID=""
        if classicApiExists "/JSSResource/osxconfigurationprofiles/name/" "$profile_name"; then
            restorePrompt "Profile" "$profile_name"
            if [[ "$RESTORE_ACTION" == "skip" ]]; then
                updateScriptLog "  Skipped: $profile_name"
                (( skipped++ )); continue
            fi
            local http_code
            http_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
                "${JAMF_URL}/JSSResource/osxconfigurationprofiles/id/${EXISTING_ID}" \
                -H "Content-Type: application/xml" \
                -H "Authorization: Bearer ${JAMF_TOKEN}" \
                --data-binary "@${xml_file}" 2>>"${scriptLog}")
            if [[ "$http_code" =~ ^2 ]]; then
                updateScriptLog "  Updated: $profile_name (ID: $EXISTING_ID)"
                (( success++ ))
            else
                updateScriptLog "  WARNING: Update failed for '$profile_name' (HTTP $http_code)"
                (( fail++ ))
            fi
        else
            local http_code
            http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
                "${JAMF_URL}/JSSResource/osxconfigurationprofiles/id/0" \
                -H "Content-Type: application/xml" \
                -H "Authorization: Bearer ${JAMF_TOKEN}" \
                --data-binary "@${xml_file}" 2>>"${scriptLog}")
            if [[ "$http_code" =~ ^2 ]]; then
                updateScriptLog "  Created: $profile_name"
                (( success++ ))
            elif [[ "$http_code" == "409" ]]; then
                updateScriptLog "  409 conflict on POST — falling back to update for '$profile_name'"
                EXISTING_ID=""
                if classicApiExists "/JSSResource/osxconfigurationprofiles/name/" "$profile_name"; then
                    local put_code
                    put_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
                        "${JAMF_URL}/JSSResource/osxconfigurationprofiles/id/${EXISTING_ID}" \
                        -H "Content-Type: application/xml" \
                        -H "Authorization: Bearer ${JAMF_TOKEN}" \
                        --data-binary "@${xml_file}" 2>>"${scriptLog}")
                    if [[ "$put_code" =~ ^2 ]]; then
                        updateScriptLog "  Updated (409 fallback): $profile_name (ID: $EXISTING_ID)"
                        (( success++ ))
                    else
                        updateScriptLog "  WARNING: 409 fallback PUT failed for '$profile_name' (HTTP $put_code)"
                        (( fail++ ))
                    fi
                else
                    updateScriptLog "  WARNING: 409 but could not resolve existing ID for '$profile_name'"
                    (( fail++ ))
                fi
            else
                updateScriptLog "  WARNING: Create failed for '$profile_name' (HTTP $http_code)"
                (( fail++ ))
            fi
        fi
    done

    updateScriptLog "Profiles restore complete: $success restored, $skipped skipped, $fail failed"
}

# =============================================================================
# restoreStaticGroups
# Restores static computer groups from XML via Classic API.
# Member computers are included in the XML; Jamf handles missing members gracefully.
# =============================================================================

function restoreStaticGroups() {
    updateScriptLog "--- Restoring static computer groups ---"
    local dir="${RESTORE_DIR}/static_groups"

    if [[ ! -d "$dir" ]]; then
        updateScriptLog "  No static_groups folder found in backup: $dir"
        return
    fi

    if [[ -z "$CLIENT_ID" ]] || [[ -z "$CLIENT_SECRET" ]]; then
        updateScriptLog "  WARNING: --client-id and --client-secret required for static groups."
        return 1
    fi

    if ! getJamfURL || ! getJamfToken; then
        updateScriptLog "  ERROR: Cannot obtain auth — skipping static group restore."
        return 1
    fi

    local success=0 fail=0 skipped=0
    local xml_file

    for xml_file in "${dir}"/*.xml; do
        [[ -f "$xml_file" ]] || continue

        local group_name
        group_name=$(sed 's/></>\
</g' "$xml_file" | awk '
            /<name>.*<\/name>/ {
                gsub(/^[[:space:]]*<name>/, ""); gsub(/<\/name>.*/, ""); print; exit
            }')

        updateScriptLog "  Static group: $group_name"

        if [[ "$DRY_RUN" == "true" ]]; then
            updateScriptLog "  [DRY-RUN] would restore static group '$group_name'"
            (( success++ )); continue
        fi

        EXISTING_ID=""
        if classicApiExists "/JSSResource/computergroups/name/" "$group_name"; then
            restorePrompt "Static group" "$group_name"
            if [[ "$RESTORE_ACTION" == "skip" ]]; then
                updateScriptLog "  Skipped: $group_name"
                (( skipped++ )); continue
            fi
            local http_code
            http_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
                "${JAMF_URL}/JSSResource/computergroups/id/${EXISTING_ID}" \
                -H "Content-Type: application/xml" \
                -H "Authorization: Bearer ${JAMF_TOKEN}" \
                --data-binary "@${xml_file}" 2>>"${scriptLog}")
            if [[ "$http_code" =~ ^2 ]]; then
                updateScriptLog "  Updated: $group_name (ID: $EXISTING_ID)"
                (( success++ ))
            else
                updateScriptLog "  WARNING: Update failed for '$group_name' (HTTP $http_code)"
                (( fail++ ))
            fi
        else
            local http_code
            http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
                "${JAMF_URL}/JSSResource/computergroups/id/0" \
                -H "Content-Type: application/xml" \
                -H "Authorization: Bearer ${JAMF_TOKEN}" \
                --data-binary "@${xml_file}" 2>>"${scriptLog}")
            if [[ "$http_code" =~ ^2 ]]; then
                updateScriptLog "  Created: $group_name"
                (( success++ ))
            elif [[ "$http_code" == "409" ]]; then
                updateScriptLog "  409 conflict on POST — falling back to update for '$group_name'"
                EXISTING_ID=""
                if classicApiExists "/JSSResource/computergroups/name/" "$group_name"; then
                    local put_code
                    put_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
                        "${JAMF_URL}/JSSResource/computergroups/id/${EXISTING_ID}" \
                        -H "Content-Type: application/xml" \
                        -H "Authorization: Bearer ${JAMF_TOKEN}" \
                        --data-binary "@${xml_file}" 2>>"${scriptLog}")
                    if [[ "$put_code" =~ ^2 ]]; then
                        updateScriptLog "  Updated (409 fallback): $group_name (ID: $EXISTING_ID)"
                        (( success++ ))
                    else
                        updateScriptLog "  WARNING: 409 fallback PUT failed for '$group_name' (HTTP $put_code)"
                        (( fail++ ))
                    fi
                else
                    updateScriptLog "  WARNING: 409 but could not resolve existing ID for '$group_name'"
                    (( fail++ ))
                fi
            else
                updateScriptLog "  WARNING: Create failed for '$group_name' (HTTP $http_code)"
                (( fail++ ))
            fi
        fi
    done

    updateScriptLog "Static groups restore complete: $success restored, $skipped skipped, $fail failed"
}

# =============================================================================
# restoreSmartGroups
# Restores smart computer groups via Platform API POST.
# Uses: POST /api/pro/v2/tenant/{tenantId}/computer-groups/smart-groups
# =============================================================================

function restoreSmartGroups() {
    updateScriptLog "--- Restoring smart computer groups ---"
    local dir="${RESTORE_DIR}/smart_groups"

    if [[ ! -d "$dir" ]]; then
        updateScriptLog "  No smart_groups folder found in backup: $dir"
        return
    fi

    # Use TARGET_TENANT_ID if set (cross-instance restore), otherwise fall back
    # to the source tenant extracted at preflight
    local effective_tenant="${TARGET_TENANT_ID:-$TENANT_ID}"
    if [[ -z "$effective_tenant" ]]; then
        updateScriptLog "  ERROR: No Tenant ID available for smart group restore."
        updateScriptLog "  Use --target-profile <profile> or --target-tenant-id <id>."
        return 1
    fi

    if ! getPlatformToken; then
        updateScriptLog "  ERROR: Cannot obtain Platform token — skipping smart group restore."
        return 1
    fi

    local platform_base="https://us.apigw.jamf.com/api/pro/v2/tenant/${effective_tenant}"
    local success=0 fail=0 skipped=0
    local json_file

    for json_file in "${dir}"/*.json; do
        [[ -f "$json_file" ]] || continue

        local group_name
        group_name=$(jq -r '.name // ""' "$json_file")

        updateScriptLog "  Smart group: $group_name"

        if [[ "$DRY_RUN" == "true" ]]; then
            updateScriptLog "  [DRY-RUN] would POST smart group '$group_name' to Platform API"
            continue
        fi

        # Check if group exists via Platform API
        local check_response check_code
        local encoded_name tmpbody
        encoded_name=$(printf '%s' "$group_name" | jq -sRr @uri 2>/dev/null || printf '%s' "$group_name")
        tmpbody=$(mktemp)
        check_code=$(curl -s -o "$tmpbody" -w "%{http_code}" -X GET \
            "${platform_base}/computer-groups/smart-groups?name=${encoded_name}" \
            -H "accept: application/json" \
            -H "Authorization: Bearer ${PLATFORM_TOKEN}" \
            2>>"${scriptLog}")
        check_response=$(cat "$tmpbody"); rm -f "$tmpbody"

        local existing_count
        existing_count=$(echo "$check_response" | jq -r --arg n "$group_name" \
            '[(.results // .) | .[] | select(.name == $n)] | length' 2>/dev/null)

        if [[ "$existing_count" -gt 0 ]]; then
            restorePrompt "Smart group" "$group_name"
            if [[ "$RESTORE_ACTION" == "skip" ]]; then
                updateScriptLog "  Skipped: $group_name"
                (( skipped++ )); continue
            fi
            # Delete existing then recreate (Platform API has no PUT for smart groups)
            local del_id
            del_id=$(echo "$check_response" | jq -r --arg n "$group_name" \
                '[(.results // .) | .[] | select(.name == $n)][0].id // ""' 2>/dev/null)
            if [[ -n "$del_id" ]]; then
                curl -s -X DELETE \
                    "${platform_base}/computer-groups/smart-groups/${del_id}" \
                    -H "Authorization: Bearer ${PLATFORM_TOKEN}" \
                    2>>"${scriptLog}" > /dev/null
            fi
        fi

        # POST the group
        local post_code
        post_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
            "${platform_base}/computer-groups/smart-groups?platform=false" \
            -H "accept: application/json" \
            -H "Authorization: Bearer ${PLATFORM_TOKEN}" \
            -H "content-type: application/json" \
            --data-binary "@${json_file}" \
            2>>"${scriptLog}")

        if [[ "$post_code" =~ ^2 ]]; then
            updateScriptLog "  Restored: $group_name"
            (( success++ ))
        elif [[ "$post_code" == "409" ]]; then
            # Group still exists (delete may have silently failed or name differs).
            # Log as a warning but don't count as a hard failure — the group is present.
            updateScriptLog "  WARNING: 409 conflict — '$group_name' already exists in target; skipping."
            (( skipped++ ))
        else
            updateScriptLog "  WARNING: Failed to restore smart group '$group_name' (HTTP $post_code)"
            (( fail++ ))
        fi
    done

    if [[ "$DRY_RUN" == "true" ]]; then
        updateScriptLog "Smart groups restore complete (DRY-RUN): previewed, no changes made"
    else
        updateScriptLog "Smart groups restore complete: $success restored, $skipped skipped, $fail failed"
    fi
}

# =============================================================================
# restorePackages
# Restores packages via jamf-cli pro packages apply (metadata) then upload (file).
# =============================================================================

function restorePackages() {
    updateScriptLog "--- Restoring packages ---"
    local dir="${RESTORE_DIR}/packages"

    if [[ ! -d "$dir" ]]; then
        updateScriptLog "  No packages folder found in backup: $dir"
        return
    fi

    local success=0 fail=0 skipped=0
    local pkg_file

    for pkg_file in "${dir}"/*.pkg "${dir}"/*.dmg "${dir}"/*.zip; do
        [[ -f "$pkg_file" ]] || continue
        local pkg_filename
        pkg_filename=$(basename "$pkg_file")
        updateScriptLog "  Package: $pkg_filename"

        if [[ "$DRY_RUN" == "true" ]]; then
            updateScriptLog "  [DRY-RUN] would upload $pkg_filename via jamf-cli pro packages upload"
            continue
        fi

        # Check if package already exists by filename
        local existing
        existing=$(jamf-cli pro packages list -o json 2>/dev/null | \
            jq -r --arg fn "$pkg_filename" '.[] | select(.fileName == $fn) | .id // ""' | head -1)

        if [[ -n "$existing" ]]; then
            restorePrompt "Package" "$pkg_filename"
            if [[ "$RESTORE_ACTION" == "skip" ]]; then
                updateScriptLog "  Skipped: $pkg_filename"
                (( skipped++ )); continue
            fi
            updateScriptLog "  Overwriting existing package: $pkg_filename"
        fi

        # Upload via jamf-cli
        if [[ "$NO_PROMPT" == "true" ]] || [[ "$OVERWRITE_ALL" == "true" ]]; then
            if jamf-cli pro packages upload "$pkg_file" --yes 2>>"${scriptLog}"; then
                updateScriptLog "  Uploaded: $pkg_filename"
                (( success++ ))
            else
                updateScriptLog "  WARNING: Upload failed for $pkg_filename"
                (( fail++ ))
            fi
        else
            if jamf-cli pro packages upload "$pkg_file" 2>>"${scriptLog}"; then
                updateScriptLog "  Uploaded: $pkg_filename"
                (( success++ ))
            else
                updateScriptLog "  WARNING: Upload failed for $pkg_filename"
                (( fail++ ))
            fi
        fi
    done

    if [[ "$DRY_RUN" == "true" ]]; then
        updateScriptLog "Packages restore complete (DRY-RUN): previewed, no changes made"
    else
        updateScriptLog "Packages restore complete: $success uploaded, $skipped skipped, $fail failed"
    fi
}

# =============================================================================
# restoreBlueprints
# Restores blueprints via jamf-cli pro blueprints apply --from-file.
# =============================================================================

function restoreBlueprints() {
    updateScriptLog "--- Restoring blueprints ---"
    local dir="${RESTORE_DIR}/blueprints"

    if [[ ! -d "$dir" ]]; then
        updateScriptLog "  No blueprints folder found in backup: $dir"
        return
    fi

    local success=0 fail=0 skipped=0
    local json_file

    # Check there are actually JSON files to process
    local bp_count
    bp_count=$(find "$dir" -maxdepth 1 -name "*.json" | wc -l | tr -d ' ')
    if [[ "$bp_count" -eq 0 ]]; then
        updateScriptLog "  No blueprint JSON files found in $dir"
        return
    fi
    updateScriptLog "  Found $bp_count blueprint files."

    while IFS= read -r json_file; do
        [[ -f "$json_file" ]] || continue
        local bp_name
        bp_name=$(jq -r '.name // ""' "$json_file")
        updateScriptLog "  Blueprint: $bp_name"

        if [[ "$DRY_RUN" == "true" ]]; then
            updateScriptLog "  [DRY-RUN] jamf-cli pro blueprints apply --from-file $json_file --yes"
            continue
        fi

        # Check if blueprint exists
        local existing
        existing=$(jamf-cli pro blueprints list -o json 2>/dev/null | \
            jq -r --arg name "$bp_name" '.[] | select(.name == $name) | .id // ""' | head -1)

        if [[ -n "$existing" ]]; then
            restorePrompt "Blueprint" "$bp_name"
            if [[ "$RESTORE_ACTION" == "skip" ]]; then
                updateScriptLog "  Skipped: $bp_name"
                (( skipped++ )); continue
            fi
        fi

        if jamf-cli pro blueprints apply --from-file "$json_file" --yes 2>>"${scriptLog}"; then
            updateScriptLog "  Restored: $bp_name"
            (( success++ ))
        else
            updateScriptLog "  WARNING: Failed to restore blueprint '$bp_name'"
            (( fail++ ))
        fi
    done < <(find "$dir" -maxdepth 1 -name "*.json")

    updateScriptLog "Blueprints restore complete: $success restored, $skipped skipped, $fail failed"
}

# =============================================================================
# restoreAppInstallerDeployments
# Restores app installer deployments via jamf-cli pro app-installer-deployments apply.
# =============================================================================

function restoreAppInstallerDeployments() {
    updateScriptLog "--- Restoring app installer deployments ---"
    local dir="${RESTORE_DIR}/app_installer_deployments"

    if [[ ! -d "$dir" ]]; then
        updateScriptLog "  No app_installer_deployments folder found in backup: $dir"
        return
    fi

    local success=0 fail=0 skipped=0

    local ai_count
    ai_count=$(find "$dir" -maxdepth 1 -name "*.json" ! -name "_all_deployments.json" | wc -l | tr -d ' ')
    if [[ "$ai_count" -eq 0 ]]; then
        updateScriptLog "  No app installer deployment JSON files found in $dir"
        return
    fi
    updateScriptLog "  Found $ai_count app installer deployment files."

    while IFS= read -r json_file; do
        [[ -f "$json_file" ]] || continue

        local app_name
        app_name=$(jq -r '.name // ""' "$json_file")
        updateScriptLog "  App installer: $app_name"

        # ── Artifact detection ──────────────────────────────────────────────
        # Filename should match the sanitized app name (or sanitized name + _ID
        # for dedup suffixes added by the backup). If it doesn't, the file is
        # likely a backup artifact (e.g. saved under a smart-group name).
        local file_basename expected_name file_base_stripped
        file_basename=$(basename "$json_file" .json)
        expected_name=$(sanitize "$app_name")
        file_base_stripped="${file_basename%_[0-9]*}"   # strip trailing _<numeric-ID> dedup suffix
        if [[ "$file_basename" != "$expected_name" ]] && [[ "$file_base_stripped" != "$expected_name" ]]; then
            updateScriptLog "  WARNING: Filename '${file_basename}.json' does not match app name '${app_name}' — possible backup artifact."
            if [[ "$DRY_RUN" != "true" ]] && [[ "$NO_PROMPT" != "true" ]]; then
                echo ""
                echo "  ┌─────────────────────────────────────────────────────────────┐"
                echo "  │ WARNING: Filename / app name mismatch detected              │"
                echo "  │   File    : ${file_basename}.json"
                echo "  │   App name: ${app_name}"
                echo "  │ This file may be a backup artifact. Applying it will        │"
                echo "  │ restore '${app_name}' using this mismatched file.           │"
                echo "  │                                                             │"
                echo "  │ [C]ontinue  [S]kip  [Q]uit   default: C                   │"
                echo -n "  └─ Choice: "
                local artifact_choice
                read -r artifact_choice
                artifact_choice="${artifact_choice:-C}"
                artifact_choice=$(echo "$artifact_choice" | tr '[:lower:]' '[:upper:]')
                case "$artifact_choice" in
                    S)
                        updateScriptLog "  Skipped (artifact mismatch): ${file_basename}.json"
                        (( skipped++ ))
                        continue
                        ;;
                    Q)
                        updateScriptLog "Restore aborted by user at artifact prompt."
                        exit 0
                        ;;
                    *)
                        updateScriptLog "  Continuing: restoring '${app_name}' from '${file_basename}.json'"
                        ;;
                esac
            fi
        fi
        # ────────────────────────────────────────────────────────────────────

        if [[ "$DRY_RUN" == "true" ]]; then
            updateScriptLog "  [DRY-RUN] jamf-cli pro app-installer-deployments apply --from-file $json_file --yes"
            (( success++ )); continue
        fi

        # Check if deployment exists by name
        local existing
        existing=$(jamf-cli pro app-installer-deployments list -o json 2>/dev/null | \
            jq -r --arg name "$app_name" '.[] | select(.name == $name) | .id // ""' | head -1)

        if [[ -n "$existing" ]]; then
            restorePrompt "App installer deployment" "$app_name"
            if [[ "$RESTORE_ACTION" == "skip" ]]; then
                updateScriptLog "  Skipped: $app_name"
                (( skipped++ )); continue
            fi
            # apply --yes handles overwrite
            if jamf-cli pro app-installer-deployments apply --from-file "$json_file" --yes 2>>"${scriptLog}"; then
                updateScriptLog "  Updated: $app_name"
                (( success++ ))
            else
                updateScriptLog "  WARNING: Failed to restore '$app_name'"
                (( fail++ ))
            fi
        else
            if jamf-cli pro app-installer-deployments apply --from-file "$json_file" 2>>"${scriptLog}"; then
                updateScriptLog "  Created: $app_name"
                (( success++ ))
            else
                updateScriptLog "  WARNING: Failed to create '$app_name'"
                (( fail++ ))
            fi
        fi
    done < <(find "$dir" -maxdepth 1 -name "*.json" ! -name "_all_deployments.json")

    updateScriptLog "App installer deployments restore complete: $success restored, $skipped skipped, $fail failed"
}

# =============================================================================
# Printers backup  (Classic API — jamf-cli pro classic-printers)
# =============================================================================

function printers() {
    updateScriptLog "--- Exporting printers ---"
    local dir="${OUTPUT_DIR}/printers"
    mkdir -p "$dir"
    local success=0 fail=0

    local list_json
    list_json=$(jamf-cli pro classic-printers list -o json 2>/dev/null)
    updateScriptLog "  List response: $(echo "$list_json" | wc -c | tr -d ' ') bytes"

    local tmpfile
    tmpfile=$(mktemp /tmp/jamf_printers.XXXXXX)
    parseJsonIdName "$list_json" > "$tmpfile"

    local count
    count=$(wc -l < "$tmpfile" | tr -d ' ')
    if [[ "$count" -eq 0 ]]; then
        updateScriptLog "  No printers found."
        rm -f "$tmpfile"
        return
    fi
    updateScriptLog "  Found $count printers."

    while IFS=$'\t' read -r printer_id printer_name; do
        [[ -z "$printer_id" ]] && continue
        local safe_name
        safe_name=$(sanitize "$printer_name")
        updateScriptLog "  Printer: $printer_name (ID: $printer_id)"
        if [[ "$DRY_RUN" == "true" ]]; then
            updateScriptLog "  [DRY-RUN] jamf-cli pro classic-printers get $printer_id -o xml > ${dir}/${safe_name}.xml"
            (( success++ ))
        elif jamf-cli pro classic-printers get "$printer_id" -o xml \
               > "${dir}/${safe_name}.xml" 2>>"${scriptLog}" && [[ -s "${dir}/${safe_name}.xml" ]]; then
            (( success++ ))
        else
            updateScriptLog "  WARNING: Failed to export printer ID $printer_id"
            rm -f "${dir}/${safe_name}.xml"
            (( fail++ ))
        fi
    done < "$tmpfile"

    rm -f "$tmpfile"
    updateScriptLog "Printers complete: $success exported, $fail failed → $dir"
}

# =============================================================================
# restorePrinters
# Restores printers via jamf-cli pro classic-printers apply (create or replace by name).
# =============================================================================

function restorePrinters() {
    updateScriptLog "--- Restoring printers ---"
    local dir="${RESTORE_DIR}/printers"

    if [[ ! -d "$dir" ]]; then
        updateScriptLog "  No printers folder found in backup: $dir"
        return
    fi

    local xml_count
    xml_count=$(find "$dir" -maxdepth 1 -name "*.xml" | wc -l | tr -d ' ')
    if [[ "$xml_count" -eq 0 ]]; then
        updateScriptLog "  No printer XML files found in $dir"
        return
    fi
    updateScriptLog "  Found $xml_count printer files."

    local success=0 fail=0 skipped=0

    while IFS= read -r xml_file; do
        [[ -f "$xml_file" ]] || continue

        local printer_name
        printer_name=$(sed 's/></></g' "$xml_file" | awk '
            /<name>.*<\/name>/ {
                gsub(/^[[:space:]]*<name>/, ""); gsub(/<\/name>.*/, ""); print; exit
            }')

        updateScriptLog "  Printer: $printer_name"

        if [[ "$DRY_RUN" == "true" ]]; then
            updateScriptLog "  [DRY-RUN] jamf-cli pro classic-printers apply --from-file $xml_file --yes"
            continue
        fi

        # Check if printer already exists by name
        local existing
        existing=$(jamf-cli pro classic-printers list -o json 2>/dev/null | \
            jq -r --arg name "$printer_name" '.[] | select(.name == $name) | .id // ""' | head -1)

        if [[ -n "$existing" ]]; then
            restorePrompt "Printer" "$printer_name"
            if [[ "$RESTORE_ACTION" == "skip" ]]; then
                updateScriptLog "  Skipped: $printer_name"
                (( skipped++ ))
                continue
            fi
        fi

        if jamf-cli pro classic-printers apply --from-file "$xml_file" --yes 2>>"${scriptLog}"; then
            updateScriptLog "  Restored: $printer_name"
            (( success++ ))
        else
            updateScriptLog "  WARNING: Failed to restore printer '$printer_name'"
            (( fail++ ))
        fi
    done < <(find "$dir" -maxdepth 1 -name "*.xml")

    if [[ "$DRY_RUN" == "true" ]]; then
        updateScriptLog "Printers restore complete (DRY-RUN): previewed, no changes made"
    else
        updateScriptLog "Printers restore complete: $success restored, $skipped skipped, $fail failed"
    fi
}

# =============================================================================
# Scripts backup  (Classic API — jamf-cli pro classic-scripts)
# =============================================================================

function scripts() {
    updateScriptLog "--- Exporting scripts ---"
    local dir="${OUTPUT_DIR}/scripts"
    mkdir -p "$dir"
    local success=0 fail=0

    local list_json
    list_json=$(jamf-cli pro classic-scripts list -o json 2>/dev/null)
    updateScriptLog "  List response: $(echo "$list_json" | wc -c | tr -d ' ') bytes"

    local tmpfile
    tmpfile=$(mktemp /tmp/jamf_scripts.XXXXXX)
    parseJsonIdName "$list_json" > "$tmpfile"

    local count
    count=$(wc -l < "$tmpfile" | tr -d ' ')
    if [[ "$count" -eq 0 ]]; then
        updateScriptLog "  No scripts found."
        rm -f "$tmpfile"
        return
    fi
    updateScriptLog "  Found $count scripts."

    while IFS=$'\t' read -r script_id script_name; do
        [[ -z "$script_id" ]] && continue
        local safe_name
        safe_name=$(sanitize "$script_name")
        updateScriptLog "  Script: $script_name (ID: $script_id)"
        if [[ "$DRY_RUN" == "true" ]]; then
            updateScriptLog "  [DRY-RUN] jamf-cli pro classic-scripts get $script_id -o xml > ${dir}/${safe_name}.xml"
            (( success++ ))
        elif jamf-cli pro classic-scripts get "$script_id" -o xml \
               > "${dir}/${safe_name}.xml" 2>>"${scriptLog}" && [[ -s "${dir}/${safe_name}.xml" ]]; then
            (( success++ ))
        else
            updateScriptLog "  WARNING: Failed to export script ID $script_id"
            rm -f "${dir}/${safe_name}.xml"
            (( fail++ ))
        fi
    done < "$tmpfile"

    rm -f "$tmpfile"
    updateScriptLog "Scripts complete: $success exported, $fail failed → $dir"
}

# =============================================================================
# restoreScripts
# Restores scripts via jamf-cli pro classic-scripts apply --from-file.
# =============================================================================

function restoreScripts() {
    updateScriptLog "--- Restoring scripts ---"
    local dir="${RESTORE_DIR}/scripts"

    if [[ ! -d "$dir" ]]; then
        updateScriptLog "  No scripts folder found in backup: $dir"
        return
    fi

    local xml_count
    xml_count=$(find "$dir" -maxdepth 1 -name "*.xml" | wc -l | tr -d ' ')
    if [[ "$xml_count" -eq 0 ]]; then
        updateScriptLog "  No script XML files found in $dir"
        return
    fi
    updateScriptLog "  Found $xml_count script files."

    local success=0 fail=0 skipped=0

    while IFS= read -r xml_file; do
        [[ -f "$xml_file" ]] || continue

        local script_name
        script_name=$(sed 's/></></g' "$xml_file" | awk '
            /<name>.*<\/name>/ {
                gsub(/^[[:space:]]*<name>/, ""); gsub(/<\/name>.*/, ""); print; exit
            }')

        updateScriptLog "  Script: $script_name"

        if [[ "$DRY_RUN" == "true" ]]; then
            updateScriptLog "  [DRY-RUN] jamf-cli pro classic-scripts apply --from-file $xml_file --yes"
            continue
        fi

        local existing
        existing=$(jamf-cli pro classic-scripts list -o json 2>/dev/null | \
            jq -r --arg name "$script_name" '.[] | select(.name == $name) | .id // ""' | head -1)

        if [[ -n "$existing" ]]; then
            restorePrompt "Script" "$script_name"
            if [[ "$RESTORE_ACTION" == "skip" ]]; then
                updateScriptLog "  Skipped: $script_name"
                (( skipped++ ))
                continue
            fi
        fi

        if jamf-cli pro classic-scripts apply --from-file "$xml_file" --yes 2>>"${scriptLog}"; then
            updateScriptLog "  Restored: $script_name"
            (( success++ ))
        else
            updateScriptLog "  WARNING: Failed to restore script '$script_name'"
            (( fail++ ))
        fi
    done < <(find "$dir" -maxdepth 1 -name "*.xml")

    if [[ "$DRY_RUN" == "true" ]]; then
        updateScriptLog "Scripts restore complete (DRY-RUN): previewed, no changes made"
    else
        updateScriptLog "Scripts restore complete: $success restored, $skipped skipped, $fail failed"
    fi
}

# =============================================================================
# Help
# =============================================================================

function showHelp() {
    cat <<EOF
Usage: $(basename "$0") [--mode backup|restore] [options]

Modes:
  --mode backup            Export Jamf Pro objects (default)
  --mode restore           Restore objects to Jamf Pro

Backup/Restore targets (use with either mode):
  --all                    Backup or restore everything
  --policies               Policies (XML)
  --profiles               macOS config profiles (XML)
  --static-groups          Static computer groups + member CSVs
                           Requires --client-id / --client-secret
  --smart-groups           Smart computer groups (JSON)
  --packages               Package files (.pkg/.dmg)
  --blueprints             Blueprints (JSON)
  --compliance             Compliance benchmarks — backup only, read-only
  --computers              Computer inventory — backup only, read-only
  --app-installers         App installer deployments (JSON)
  --printers               Printers (XML per printer)
  --scripts                Scripts (XML per script)

Restore options:
  --source <path>          Dated backup folder to restore from
                           Default: most recent under output-dir
  --target-url <url>       Jamf Pro URL to restore to (Classic API)
                           Default: current instance
  --target-profile <name>  jamf-cli profile for the target instance
                           Automatically sets --target-url and --target-tenant-id
                           from that profile's config
  --target-tenant-id <id>  Tenant ID for the target instance (Platform API)
                           Derived automatically from --target-profile if omitted
  --no-prompt              Skip all conflict prompts; overwrite everything

Global options:
  --client-id      OAuth client ID for Classic API (static groups)
                   Env var: JAMF_CLIENT_ID
  --client-secret  OAuth client secret for Classic API
                   Env var: JAMF_CLIENT_SECRET
  --output-dir <path>      Base directory (default: ~/Desktop/Jamf_Pro_Backup)
  --log-file <path>        Log file path (default: <output-dir>/jamf_cli_logs.log)
  -n, --dry-run            Preview without executing
  --help                   Show this help

Conflict handling (restore mode):
  When an object already exists, you will be prompted:
  [O]verwrite  [S]kip  [A]ll (overwrite all remaining)  [Q]uit   default: O

Read-only objects (never restored):
  computers/, compliance/  — informational only, skipped automatically

Examples:
  # Full backup
  ./jamf_backup.sh --mode backup --all

  # Backup with static groups
  ./jamf_backup.sh --mode backup --all \\
    --client-id CLIENT_ID --client-secret CLIENT_SECRET

  # Restore most recent backup to same instance
  ./jamf_backup.sh --mode restore --all \\
    --client-id CLIENT_ID --client-secret CLIENT_SECRET

  # Restore to a different Jamf instance using a configured jamf-cli profile
  ./jamf_backup.sh --mode restore --all --no-prompt \\
    --source ~/Desktop/Jamf_Pro_Backup/2026_05_28 \\
    --target-profile newinstance \\
    --client-id CLIENT_ID --client-secret CLIENT_SECRET

  # Restore specific backup to new instance, no prompts
  ./jamf_backup.sh --mode restore --all --no-prompt \\
    --source ~/Desktop/Jamf_Pro_Backup/2026_05_27 \\
    --target-url https://newinstance.jamfcloud.com \\
    --client-id CLIENT_ID --client-secret CLIENT_SECRET

  # Dry run restore to preview what would happen
  ./jamf_backup.sh --mode restore --all --dry-run \\
    --source ~/Desktop/Jamf_Pro_Backup/2026_05_27
EOF
}

# =============================================================================
# Argument parsing
# =============================================================================

if [[ $# -eq 0 ]]; then
    showHelp
    exit 0
fi

run_policies=false
run_profiles=false
run_static=false
run_smart=false
run_packages=false
run_blueprints=false
run_compliance=false
run_computers=false
run_app_installers=false
run_printers=false
run_scripts=false
run_all=false
unknown_args=()
custom_output_dir=""
custom_log_file=""
DRY_RUN=false

i=0
args=("$@")
while [[ $i -lt ${#args[@]} ]]; do
    arg="${args[$i]}"
    case "$arg" in
        --mode)
            (( i++ ))
            SCRIPT_MODE="${args[$i]}"
            ;;
        --mode=*)
            SCRIPT_MODE="${arg#--mode=}"
            ;;
        --all)              run_all=true ;;
        --policies)         run_policies=true ;;
        --profiles)         run_profiles=true ;;
        --static-groups)    run_static=true ;;
        --smart-groups)     run_smart=true ;;
        --packages)         run_packages=true ;;
        --blueprints)       run_blueprints=true ;;
        --compliance)       run_compliance=true ;;
        --computers)        run_computers=true ;;
        --app-installers)   run_app_installers=true ;;
        --printers)         run_printers=true ;;
        --scripts)          run_scripts=true ;;
        --help)             showHelp; exit 0 ;;
        --output-dir)
            (( i++ ))
            custom_output_dir="${args[$i]}"
            ;;
        --output-dir=*)
            custom_output_dir="${arg#--output-dir=}"
            ;;
        --log-file)
            (( i++ ))
            custom_log_file="${args[$i]}"
            ;;
        --log-file=*)
            custom_log_file="${arg#--log-file=}"
            ;;
        --source)
            (( i++ ))
            RESTORE_SOURCE="${args[$i]}"
            ;;
        --source=*)
            RESTORE_SOURCE="${arg#--source=}"
            ;;
        --target-url)
            (( i++ ))
            RESTORE_TARGET_URL="${args[$i]}"
            ;;
        --target-url=*)
            RESTORE_TARGET_URL="${arg#--target-url=}"
            ;;
        --target-profile)
            (( i++ ))
            TARGET_PROFILE="${args[$i]}"
            ;;
        --target-profile=*)
            TARGET_PROFILE="${arg#--target-profile=}"
            ;;
        --target-tenant-id)
            (( i++ ))
            TARGET_TENANT_ID="${args[$i]}"
            ;;
        --target-tenant-id=*)
            TARGET_TENANT_ID="${arg#--target-tenant-id=}"
            ;;
        --no-prompt)
            NO_PROMPT=true
            ;;
        -n|--dry-run)
            DRY_RUN=true
            ;;
        --client-id)
            (( i++ ))
            CLIENT_ID="${args[$i]}"
            ;;
        --client-id=*)
            CLIENT_ID="${arg#--client-id=}"
            ;;
        --client-secret)
            (( i++ ))
            CLIENT_SECRET="${args[$i]}"
            ;;
        --client-secret=*)
            CLIENT_SECRET="${arg#--client-secret=}"
            ;;
        *)
            unknown_args+=("$arg")
            ;;
    esac
    (( i++ ))
done

if [[ ${#unknown_args[@]} -gt 0 ]]; then
    echo "ERROR: Unknown argument(s): ${unknown_args[*]}"
    echo ""
    showHelp
    exit 1
fi

# Env var fallbacks for Classic API credentials (override with --client-id / --client-secret)
[[ -z "$CLIENT_ID" ]]     && CLIENT_ID="${JAMF_CLIENT_ID:-}"
[[ -z "$CLIENT_SECRET" ]] && CLIENT_SECRET="${JAMF_CLIENT_SECRET:-}"

if [[ "$SCRIPT_MODE" != "backup" ]] && [[ "$SCRIPT_MODE" != "restore" ]]; then
    echo "ERROR: --mode must be 'backup' or 'restore' (got: '$SCRIPT_MODE')"
    exit 1
fi

[[ -n "$custom_output_dir" ]] && OUTPUT_BASE="$custom_output_dir"
OUTPUT_DIR="${OUTPUT_BASE}/${currentYear}_${currentMonth}_${currentDate}_${currentTime}"
if [[ -n "$custom_log_file" ]]; then
    scriptLog="$custom_log_file"
else
    scriptLog="${OUTPUT_BASE}/jamf_cli_logs.log"
fi

# =============================================================================
# Run
# =============================================================================

preflight

if [[ "$DRY_RUN" == "true" ]]; then
    updateScriptLog "DRY-RUN MODE — commands will be shown but not executed"
    updateScriptLog "  MODE       : $SCRIPT_MODE"
    updateScriptLog "  OUTPUT_DIR : $OUTPUT_DIR"
    updateScriptLog "  scriptLog  : $scriptLog"
    updateScriptLog "  jamf-cli   : $(which jamf-cli 2>/dev/null)"
    updateScriptLog "  version    : $(jamf-cli version 2>/dev/null | head -1)"
    updateScriptLog "  profile    : $(jamf-cli config list 2>/dev/null | tr -d '\n' | head -c 200)"
fi

# ── BACKUP MODE ───────────────────────────────────────────────────────────────
if [[ "$SCRIPT_MODE" == "backup" ]]; then
    updateScriptLog "=== Starting backup → $OUTPUT_DIR ==="

    if $run_all; then
        policies
        profiles
        staticGroups
        smartGroups
        packages
        blueprints
        compliance
        computers
        appInstallerDeployments
        printers
        scripts
    else
        $run_policies       && policies
        $run_profiles       && profiles
        $run_static         && staticGroups
        $run_smart          && smartGroups
        $run_packages       && packages
        $run_blueprints     && blueprints
        $run_compliance     && compliance
        $run_computers      && computers
        $run_app_installers && appInstallerDeployments
        $run_printers       && printers
        $run_scripts        && scripts
    fi

    updateScriptLog "=== Backup complete → $OUTPUT_DIR ==="

# ── RESTORE MODE ──────────────────────────────────────────────────────────────
elif [[ "$SCRIPT_MODE" == "restore" ]]; then
    findRestoreSource
    updateScriptLog "=== Starting restore from $RESTORE_DIR ==="

    # If --target-profile was given, derive URL and tenant ID from it now
    resolveTargetProfile

    if [[ "$NO_PROMPT" == "true" ]]; then
        updateScriptLog "  No-prompt mode: all conflicts will be overwritten automatically."
    fi

    # ── Classic API credential pre-flight ────────────────────────────────────
    # Policies, config profiles, and static groups all require a Classic API
    # OAuth client. Catch missing credentials here — before any work begins —
    # so the operator gets a single clear error rather than three silent skips.
    _needs_classic=false
    if $run_all || $run_policies || $run_profiles || $run_static; then
        _needs_classic=true
    fi
    if [[ "$_needs_classic" == "true" ]] && { [[ -z "$CLIENT_ID" ]] || [[ -z "$CLIENT_SECRET" ]]; }; then
        updateScriptLog "ERROR: --policies, --profiles, and --static-groups require Classic API credentials."
        updateScriptLog "  Re-run with: --client-id <id> --client-secret <secret>"
        updateScriptLog "  Create an API client in Jamf Pro: Settings → System → API Roles and Clients"
        exit 1
    fi
    # ─────────────────────────────────────────────────────────────────────────

    if $run_all; then
        restorePolicies
        restoreProfiles
        restoreStaticGroups
        restoreSmartGroups
        restorePackages
        restoreBlueprints
        restoreAppInstallerDeployments
        restorePrinters
        restoreScripts
        updateScriptLog "  NOTE: computers/ and compliance/ are read-only exports — not restored."
    else
        $run_policies       && restorePolicies
        $run_profiles       && restoreProfiles
        $run_static         && restoreStaticGroups
        $run_smart          && restoreSmartGroups
        $run_packages       && restorePackages
        $run_blueprints     && restoreBlueprints
        $run_app_installers && restoreAppInstallerDeployments
        $run_printers       && restorePrinters
        $run_scripts        && restoreScripts
        if $run_compliance || $run_computers; then
            updateScriptLog "  NOTE: computers/ and compliance/ are read-only exports — not restored."
        fi
    fi

    updateScriptLog "=== Restore complete from $RESTORE_DIR ==="
fi