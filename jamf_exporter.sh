#!/bin/bash

# =============================================================================
# jamf_backup.sh
# Exports Jamf Pro objects using jamf-cli to dated output directories.
#
# Usage:
#   ./jamf_backup.sh [options]
#
# Options:
#   --all                  Export everything
#   --policies             Export policies (XML per policy)
#   --profiles             Export macOS config profiles (XML per profile)
#   --static-groups        Export static computer groups + member CSVs
#   --smart-groups         Export smart computer groups (JSON per group)
#   --packages             Download actual .pkg/.dmg files from JCDS
#   --blueprints           Export blueprints via Platform API
#   --compliance           Export compliance benchmarks via Platform API
#   --output-dir <path>    Base output directory (default: ~/Desktop/Jamf_Pro_Backup)
#   --log-file <path>      Log file path (default: <output-dir>/jamf_cli_logs.log)
#   -n, --dry-run          Preview all jamf-cli commands without executing them
#   --help                 Show this help message
#
# Requirements:
#   jamf-cli installed and a profile configured.
#   Install:  https://github.com/Jamf-Concepts/jamf-cli
#   Setup:    https://github.com/Jamf-Concepts/jamf-cli/wiki/Setup-Guide
# =============================================================================

# bash 3.2 compatible — no mapfile, no ${var^}, no associative arrays

currentYear=$(date +%Y)
currentMonth=$(date +%m)
currentDate=$(date +%d)
currentUser=$(stat -f "%Su" /dev/console)

OUTPUT_BASE="/Users/${currentUser}/Desktop/Jamf_Pro_Backup"
OUTPUT_DIR=""
scriptLog=""
CLASSIC_CLIENT_ID=""
CLASSIC_CLIENT_SECRET=""

# =============================================================================
# Logging
# =============================================================================

function updateScriptLog() {
    echo -e "$(date +%Y-%m-%d\ %H:%M:%S) - ${1}" | tee -a "${scriptLog}"
}

function debugLog() {
    [[ "$DRY_RUN" == "true" ]] || return
    echo -e "$(date +%Y-%m-%d\ %H:%M:%S) - [DRY-RUN] ${1}" | tee -a "${scriptLog}"
}

# =============================================================================
# Pre-flight
# =============================================================================

function preflight() {
    if [[ ! -d "$OUTPUT_DIR" ]]; then
        mkdir -p "$OUTPUT_DIR"
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

    local configList
    configList=$(jamf-cli config list 2>&1)
    if [[ "$configList" == *"No Profiles Configured"* ]] || [[ "$configList" == "[]" ]]; then
        updateScriptLog "ERROR: No jamf-cli profiles configured."
        updateScriptLog "Run: jamf-cli pro setup --url https://your.jamfcloud.com"
        exit 1
    fi
    updateScriptLog "jamf-cli profile(s) detected."
    updateScriptLog "Output directory: $OUTPUT_DIR"
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
# Uses grep + sed only — no python, no gawk 3-arg match.
# jamf-cli always pretty-prints JSON with one key per line.
# ---------------------------------------------------------------------------
function parseJsonIdName() {
    local json="$1"

    local ids names
    ids=$(echo "$json" | \
        grep -o '"id"[[:space:]]*:[[:space:]]*"*[0-9a-zA-Z_-]*"*' | \
        sed 's/"id"[[:space:]]*:[[:space:]]*//;s/"//g' | \
        grep -v '^$')

    names=$(echo "$json" | \
        grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' | \
        sed 's/"name"[[:space:]]*:[[:space:]]*"//;s/"$//')

    debugLog "parseJsonIdName: $(echo "$ids" | grep -c .) IDs, $(echo "$names" | grep -c .) names extracted"
    paste <(echo "$ids") <(echo "$names") | grep -v $'^\t$'
}

# ---------------------------------------------------------------------------
# getJamfURL
# Extracts the Jamf Pro base URL from jamf checkjssconnection output.
# Sets global JAMF_URL on success.
# ---------------------------------------------------------------------------
JAMF_URL=""

function getJamfURL() {
    [[ -n "$JAMF_URL" ]] && return 0

    local raw
    raw=$(jamf checkjssconnection 2>/dev/null)

    # Output: "Checking availability of https://example.jamfcloud.com/..."
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
# Obtains a Bearer token for the Classic API (/JSSResource) via OAuth2
# client credentials passed in via --classic-client-id and --classic-client-secret.
#
# Sets global JAMF_TOKEN on success. Reuses token within the same run.
# ---------------------------------------------------------------------------
JAMF_TOKEN=""

function getJamfToken() {
    [[ -n "$JAMF_TOKEN" ]] && return 0

    if ! getJamfURL; then
        return 1
    fi

    if [[ -z "$CLASSIC_CLIENT_ID" ]] || [[ -z "$CLASSIC_CLIENT_SECRET" ]]; then
        updateScriptLog "  ERROR: Classic API credentials not provided."
        updateScriptLog "  Re-run with: --classic-client-id <id> --classic-client-secret <secret>"
        updateScriptLog "  Create an API client in Jamf Pro: Settings → System → API Roles and Clients"
        return 1
    fi

    updateScriptLog "  Obtaining Classic API token via OAuth client credentials..."

    local response http_code
    response=$(curl -s -w "\n__HTTP_CODE__:%{http_code}" -X POST \
        "${JAMF_URL}/api/oauth/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=client_credentials&client_id=${CLASSIC_CLIENT_ID}&client_secret=${CLASSIC_CLIENT_SECRET}" \
        2>>"${scriptLog}")

    http_code=$(echo "$response" | grep "__HTTP_CODE__:" | sed 's/.*__HTTP_CODE__://')
    response=$(echo "$response" | grep -v "__HTTP_CODE__:")

    if [[ "$http_code" == "200" ]]; then
        JAMF_TOKEN=$(echo "$response" | /usr/bin/python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('access_token', ''))
" 2>/dev/null)
    fi

    if [[ -z "$JAMF_TOKEN" ]]; then
        updateScriptLog "  ERROR: OAuth token request failed (HTTP ${http_code}): ${response:0:100}"
        return 1
    fi

    updateScriptLog "  Classic API token obtained successfully."
    return 0
}


# ---------------------------------------------------------------------------
# xmlExtractMembers <xml_string> <group_id> <group_name>
# Parses Classic API computer group XML and prints CSV rows to stdout.
# Handles <computers><computer><id/><name/><serial_number/></computer></computers>
# ---------------------------------------------------------------------------
function xmlExtractMembers() {
    local xml="$1"
    local gid="$2"
    local gname="$3"

    # Safe group name for CSV — escape embedded double quotes
    local safe_gname="${gname//\"/\"\"}"

    # Only capture fields inside <computer>...</computer> blocks.
    # Uses an in_computer flag to ignore <id> tags outside computer blocks
    # (e.g. inside <site>, <criteria>, <computer_group> root level).
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
# Python 3 availability
# Compliance parsing requires python3. This function ensures it is present,
# attempting CLT install via softwareupdate, then Homebrew as a last resort.
# Sets the global PYTHON3_BIN variable on success.
# =============================================================================

PYTHON3_BIN=""

function ensurePython3() {
    # Check standard system path first
    if /usr/bin/python3 --version &>/dev/null; then
        updateScriptLog "  python3 found at /usr/bin/python3"
        PYTHON3_BIN="/usr/bin/python3"
        return 0
    fi

    # Check common Homebrew locations
    local p
    for p in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
        if [[ -x "$p" ]]; then
            updateScriptLog "  python3 found at $p"
            PYTHON3_BIN="$p"
            return 0
        fi
    done

    updateScriptLog "  python3 not found — attempting install via Xcode Command Line Tools..."

    # softwareupdate-based CLT install works headless (no GUI prompt)
    local clt_label
    clt_label=$(softwareupdate -l 2>/dev/null | \
        grep -i "command line tools" | \
        sort -r | head -1 | \
        sed 's/.*\* //' | \
        xargs)

    if [[ -n "$clt_label" ]]; then
        updateScriptLog "  Installing: $clt_label"
        softwareupdate -i "$clt_label" --agree-to-license 2>>"${scriptLog}"
    else
        updateScriptLog "  No CLT package found via softwareupdate."
    fi

    # Re-check after CLT attempt
    if /usr/bin/python3 --version &>/dev/null; then
        updateScriptLog "  python3 now available after CLT install."
        PYTHON3_BIN="/usr/bin/python3"
        return 0
    fi

    # Homebrew last resort — check both Apple Silicon and Intel paths
    local brew_bin=""
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [[ -x "$b" ]] && brew_bin="$b" && break
    done

    if [[ -n "$brew_bin" ]]; then
        updateScriptLog "  Attempting: brew install python3"
        "$brew_bin" install python3 2>>"${scriptLog}"
        for p in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
            if [[ -x "$p" ]]; then
                updateScriptLog "  python3 available after Homebrew install: $p"
                PYTHON3_BIN="$p"
                return 0
            fi
        done
    fi

    updateScriptLog "  ERROR: Could not obtain python3. Compliance export will be skipped."
    return 1
}

# =============================================================================
# Policies  (Classic API)
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
# macOS Configuration Profiles  (Classic API)
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
# Computer Groups
#
# List:  jamf-cli pro static-computer-groups list  /  smart-computer-groups list
# Get:   jamf-cli pro static-computer-groups get <id>  — returns metadata only
#
# Member data: the modern static-computer-groups endpoint does NOT return
# membership. We use jamf-cli pro computer-groups get <id> -o xml which
# hits the Classic API and includes the full <computers> block.
# =============================================================================

function computerGroups() {
    local mode="$1"
    local mode_label
    mode_label=$(ucfirst "$mode")
    local dir="${OUTPUT_DIR}/${mode}_groups"
    mkdir -p "$dir"
    local success=0 fail=0

    updateScriptLog "--- Exporting ${mode} computer groups ---"

    # ------------------------------------------------------------------
    # Static groups: use Classic API entirely via curl.
    #   Step 1: GET /JSSResource/computergroups — list all, filter is_smart=false
    #   Step 2: GET /JSSResource/computergroups/id/{id} — fetch members per group
    # Smart groups: use jamf-cli pro smart-computer-groups list + get
    # ------------------------------------------------------------------

    if [[ "$mode" == "static" ]]; then

        if [[ -z "$CLASSIC_CLIENT_ID" ]] || [[ -z "$CLASSIC_CLIENT_SECRET" ]]; then
            updateScriptLog "  WARNING: --classic-client-id and --classic-client-secret are required to export static group members."
            updateScriptLog "  Skipping static groups. Re-run with Classic API credentials to include member data."
            return 1
        fi

        if ! getJamfURL || ! getJamfToken; then
            updateScriptLog "  ERROR: Cannot fetch auth — skipping static groups."
            return 1
        fi

        # Step 1 — fetch full group list and extract static group IDs + names
        local all_groups_xml
        local http_code
        all_groups_xml=$(curl -s -w "\n__HTTP_CODE__:%{http_code}" -X GET \
            "${JAMF_URL}/JSSResource/computergroups" \
            -H "accept: application/xml" \
            -H "Authorization: Bearer ${JAMF_TOKEN}" \
            2>>"${scriptLog}")

        http_code=$(echo "$all_groups_xml" | grep "__HTTP_CODE__:" | sed 's/.*__HTTP_CODE__://')
        all_groups_xml=$(echo "$all_groups_xml" | grep -v "__HTTP_CODE__:")
        updateScriptLog "  /JSSResource/computergroups HTTP status: ${http_code}"
        updateScriptLog "  Response bytes: ${#all_groups_xml}"
        updateScriptLog "  Response preview: ${all_groups_xml:0:200}"

        if [[ -z "$all_groups_xml" ]] || [[ "$http_code" != "200" ]]; then
            updateScriptLog "  ERROR: Bad response from /JSSResource/computergroups (HTTP ${http_code})"
            return 1
        fi

        # Parse static group id+name pairs from XML using awk.
        # Normalize single-line XML to one tag per line first, then parse.
        local id_name_tmp
        id_name_tmp=$(mktemp /tmp/jamf_grp_ids.XXXXXX)

        echo "$all_groups_xml" | sed 's/></>\'$'\n''</g' | awk '
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
            rm -f "$id_name_tmp"
            return
        fi
        updateScriptLog "  Found $count static computer groups."

        # Combined members CSV
        local members_csv="${dir}/_all_members.csv"
        echo "group_id,group_name,computer_id,computer_name,serial_number" > "$members_csv"

        while IFS=$'\t' read -r group_id group_name; do
            [[ -z "$group_id" ]] && continue
            local safe_name
            safe_name=$(sanitize "$group_name")
            updateScriptLog "  Static group: $group_name (ID: $group_id)"

            if [[ "$DRY_RUN" == "true" ]]; then
                updateScriptLog "  [DRY-RUN] curl GET ${JAMF_URL}/JSSResource/computergroups/id/${group_id}"
                (( success++ ))
                continue
            fi

            # Step 2 — fetch individual group for members
            local group_xml group_http_code
            group_xml=$(curl -s -w "\n__HTTP_CODE__:%{http_code}" -X GET \
                "${JAMF_URL}/JSSResource/computergroups/id/${group_id}" \
                -H "accept: application/xml" \
                -H "Authorization: Bearer ${JAMF_TOKEN}" \
                2>>"${scriptLog}")

            group_http_code=$(echo "$group_xml" | grep "__HTTP_CODE__:" | sed 's/.*__HTTP_CODE__://')
            group_xml=$(echo "$group_xml" | grep -v "__HTTP_CODE__:")

            if [[ -z "$group_xml" ]] || [[ "$group_http_code" != "200" ]]; then
                updateScriptLog "  WARNING: Bad response for group $group_id (HTTP ${group_http_code}): ${group_xml:0:100}"
                (( fail++ ))
                continue
            fi

            # Save full group XML as JSON-equivalent record
            echo "$group_xml" > "${dir}/${safe_name}.xml"
            (( success++ ))

            # Extract members to per-group CSV
            local group_csv="${dir}/${safe_name}_members.csv"
            echo "group_id,group_name,computer_id,computer_name,serial_number" > "$group_csv"
            xmlExtractMembers "$group_xml" "$group_id" "$group_name" >> "$group_csv"

            local member_count
            member_count=$(( $(wc -l < "$group_csv" | tr -d ' ') - 1 ))
            updateScriptLog "    → $member_count members → ${safe_name}_members.csv"

            # Append to combined CSV (skip header)
            tail -n +2 "$group_csv" >> "$members_csv"

        done < "$id_name_tmp"

        local total_members
        total_members=$(( $(wc -l < "$members_csv" | tr -d ' ') - 1 ))
        updateScriptLog "  Combined members CSV: $total_members rows → $members_csv"
        rm -f "$id_name_tmp"

    else
        # Smart groups — jamf-cli path unchanged
        local subcmd="smart-computer-groups"

        local list_json
        list_json=$(jamf-cli pro "$subcmd" list -o json 2>/dev/null)
        local raw_bytes
        raw_bytes=$(echo "$list_json" | wc -c | tr -d ' ')
        updateScriptLog "  List response: ${raw_bytes} bytes"

        if [[ "$raw_bytes" -lt 5 ]]; then
            updateScriptLog "  ERROR: Empty response from jamf-cli pro $subcmd list"
            return 1
        fi

        local id_name_tmp
        id_name_tmp=$(mktemp /tmp/jamf_grp_ids.XXXXXX)
        parseJsonIdName "$list_json" > "$id_name_tmp"

        local count
        count=$(wc -l < "$id_name_tmp" | tr -d ' ')
        if [[ "$count" -eq 0 ]]; then
            updateScriptLog "  No smart groups found."
            updateScriptLog "  JSON snippet: $(echo "$list_json" | head -c 400)"
            rm -f "$id_name_tmp"
            return
        fi
        updateScriptLog "  Found $count smart computer groups."

        while IFS=$'\t' read -r group_id group_name; do
            [[ -z "$group_id" ]] && continue
            local safe_name
            safe_name=$(sanitize "$group_name")
            updateScriptLog "  Smart group: $group_name (ID: $group_id)"

            if [[ "$DRY_RUN" == "true" ]]; then
                updateScriptLog "  [DRY-RUN] jamf-cli pro $subcmd get $group_id -o json > ${dir}/${safe_name}.json"
                (( success++ ))
                continue
            fi

            local group_json
            group_json=$(jamf-cli pro "$subcmd" get "$group_id" -o json 2>/dev/null)
            if [[ -z "$group_json" ]]; then
                updateScriptLog "  WARNING: Empty response for group $group_id"
                (( fail++ ))
                continue
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
# Packages — download actual .pkg/.dmg files via jamf-cli pro jcds
#
# jcds list   → JSON array: [{"fileName":"Foo.pkg","length":N,...}, ...]
# jcds download <fileName> --output <full-file-path>
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

    # Extract "fileName" values — grep+sed, no gawk
    local tmpfile
    tmpfile=$(mktemp /tmp/jamf_jcds_names.XXXXXX)
    echo "$jcds_json" | \
        grep -o '"fileName"[[:space:]]*:[[:space:]]*"[^"]*"' | \
        sed 's/"fileName"[[:space:]]*:[[:space:]]*"//;s/"$//' > "$tmpfile"

    local total
    total=$(wc -l < "$tmpfile" | tr -d ' ')
    updateScriptLog "  Found $total files in JCDS."

    if [[ "$total" -eq 0 ]]; then
        updateScriptLog "  Raw snippet: $(echo "$jcds_json" | head -c 400)"
        rm -f "$tmpfile"
        return
    fi

    while IFS= read -r pkg_filename; do
        [[ -z "$pkg_filename" ]] && continue
        updateScriptLog "  Downloading: $pkg_filename"

        local dest="${dir}/${pkg_filename}"

        if [[ -f "$dest" ]]; then
            updateScriptLog "  Already exists, skipping."
            (( skipped++ ))
            continue
        fi

        debugLog "jcds download \"$pkg_filename\" --output \"$dest\""
        if [[ "$DRY_RUN" == "true" ]]; then
            updateScriptLog "  [DRY-RUN] jamf-cli pro jcds download \"$pkg_filename\" --output \"$dest\""
            (( success++ ))
        elif jamf-cli pro jcds download "$pkg_filename" \
               --output "$dest" 2>>"${scriptLog}"; then
            local filesize
            filesize=$(du -sh "$dest" 2>/dev/null | cut -f1)
            updateScriptLog "  Done: $pkg_filename ($filesize)"
            (( success++ ))
        else
            updateScriptLog "  WARNING: Download failed for $pkg_filename"
            debugLog "dest path was: $dest"
            (( fail++ ))
        fi
    done < "$tmpfile"

    rm -f "$tmpfile"
    updateScriptLog "Packages complete: $success downloaded, $skipped skipped, $fail failed → $dir"
}

# =============================================================================
# Blueprints  (Platform API — jamf-cli pro blueprints)
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
        rm -f "$tmpfile"
        return
    fi
    updateScriptLog "  Found $count blueprints."

    while IFS=$'\t' read -r bp_id bp_name; do
        [[ -z "$bp_id" ]] && continue
        local safe_name
        safe_name=$(sanitize "$bp_name")
        updateScriptLog "  Blueprint: $bp_name (ID: $bp_id)"
        if [[ "$DRY_RUN" == "true" ]]; then
            updateScriptLog "  [DRY-RUN] jamf-cli pro blueprints get $bp_id -o json > ${dir}/${safe_name}.json"
            (( success++ ))
        elif jamf-cli pro blueprints get "$bp_id" -o json \
               > "${dir}/${safe_name}.json" 2>>"${scriptLog}" && [[ -s "${dir}/${safe_name}.json" ]]; then
            (( success++ ))
        else
            updateScriptLog "  WARNING: Failed to export blueprint ID $bp_id"
            rm -f "${dir}/${safe_name}.json"
            (( fail++ ))
        fi
    done < "$tmpfile"

    rm -f "$tmpfile"
    updateScriptLog "Blueprints complete: $success exported, $fail failed → $dir"
}

# =============================================================================
# Compliance Benchmarks  (Platform API — jamf-cli pro compliance-benchmarks)
#
# The compliance API returns objects with non-standard field names:
#   id field  → "id" or "benchmarkId"
#   name field → "baselineId" or "description" (NOT "name")
# parseJsonIdName cannot handle this, so we use python3 to parse the JSON.
# ensurePython3 must succeed before this function proceeds.
# =============================================================================

function compliance() {
    updateScriptLog "--- Exporting compliance benchmarks ---"

    if ! ensurePython3; then
        updateScriptLog "  Skipping compliance export — python3 unavailable."
        return 1
    fi

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

    # Extract IDs only from the list — title/name are not present in list response,
    # only in the individual get response. We fetch each record individually and
    # derive the filename from the get response itself.
    local tmpfile
    tmpfile=$(mktemp /tmp/jamf_compliance.XXXXXX)

    "$PYTHON3_BIN" -c "
import sys, json
data = json.loads(sys.argv[1])
if not isinstance(data, list):
    data = data.get('results', data.get('items', data.get('benchmarks', [])))
for item in data:
    bid = item.get('id') or item.get('benchmarkId') or item.get('_id', '')
    if bid:
        print(bid)
" "$list_json" > "$tmpfile" 2>>"${scriptLog}"

    local count
    count=$(wc -l < "$tmpfile" | tr -d ' ')
    if [[ "$count" -eq 0 ]]; then
        updateScriptLog "  No compliance benchmarks found."
        updateScriptLog "  (Requires platform auth-method profile + Jamf Security Cloud license)"
        rm -f "$tmpfile"
        return
    fi
    updateScriptLog "  Found $count benchmarks."

    while IFS= read -r bench_id; do
        [[ -z "$bench_id" ]] && continue

        if [[ "$DRY_RUN" == "true" ]]; then
            updateScriptLog "  [DRY-RUN] jamf-cli pro compliance-benchmarks get $bench_id -o json"
            (( success++ ))
            continue
        fi

        # Fetch the full record
        local bench_json
        bench_json=$(jamf-cli pro compliance-benchmarks get "$bench_id" -o json 2>>"${scriptLog}")

        if [[ -z "$bench_json" ]]; then
            updateScriptLog "  WARNING: Empty response for benchmark ID $bench_id"
            (( fail++ ))
            continue
        fi

        # Derive filename from title > baselineId > id
        local bench_name
        bench_name=$("$PYTHON3_BIN" -c "
import sys, json
data = json.loads(sys.argv[1])
label = data.get('title') or data.get('baselineId') or data.get('name') or ''
print(label.strip()[:80])
" "$bench_json" 2>/dev/null)

        local safe_name
        safe_name=$(sanitize "$bench_name")
        [[ -z "$safe_name" ]] && safe_name="$bench_id"

        updateScriptLog "  Benchmark: $bench_name (ID: $bench_id)"

        local out_file="${dir}/${safe_name}.json"

        if echo "$bench_json" > "$out_file" && [[ -s "$out_file" ]]; then
            (( success++ ))
        else
            updateScriptLog "  WARNING: Failed to write benchmark ID $bench_id"
            rm -f "$out_file"
            (( fail++ ))
        fi
    done < "$tmpfile"

    rm -f "$tmpfile"
    updateScriptLog "Compliance complete: $success exported, $fail failed → $dir"
}

# =============================================================================
# Computers  (Pro API — jamf-cli pro computers list)
# Exports the full computer inventory as a single JSON file.
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
        rm -f "$out_file"
        return 1
    fi
}

# =============================================================================
# App Installer Deployments  (Pro API — jamf-cli pro app-installer-deployments)
# List all deployments, then get full detail per deployment (JSON per app).
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

    # Save the full list as a summary file
    echo "$list_json" > "${dir}/_all_deployments.json"

    local tmpfile
    tmpfile=$(mktemp /tmp/jamf_appinstaller.XXXXXX)
    parseJsonIdName "$list_json" > "$tmpfile"

    local count
    count=$(wc -l < "$tmpfile" | tr -d ' ')
    if [[ "$count" -eq 0 ]]; then
        updateScriptLog "  No app installer deployments found."
        rm -f "$tmpfile"
        return
    fi
    updateScriptLog "  Found $count app installer deployments."

    while IFS=$'	' read -r app_id app_name; do
        [[ -z "$app_id" ]] && continue
        local safe_name
        safe_name=$(sanitize "$app_name")
        [[ -z "$safe_name" ]] && safe_name="$app_id"
        updateScriptLog "  App: $app_name (ID: $app_id)"

        if [[ "$DRY_RUN" == "true" ]]; then
            updateScriptLog "  [DRY-RUN] jamf-cli pro app-installer-deployments get $app_id -o json > ${dir}/${safe_name}.json"
            (( success++ ))
            continue
        fi

        local out_file="${dir}/${safe_name}.json"
        if jamf-cli pro app-installer-deployments get "$app_id" -o json                > "$out_file" 2>>"${scriptLog}" && [[ -s "$out_file" ]]; then
            (( success++ ))
        else
            updateScriptLog "  WARNING: Failed to export deployment ID $app_id"
            rm -f "$out_file"
            (( fail++ ))
        fi
    done < "$tmpfile"

    rm -f "$tmpfile"
    updateScriptLog "App installer deployments complete: $success exported, $fail failed → $dir"
}

# =============================================================================
# Help
# =============================================================================

function showHelp() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --all                  Export everything
  --policies             Export policies (XML per policy)
  --profiles             Export macOS config profiles (XML per profile)
  --static-groups        Export static computer groups + per-group member CSVs
  --smart-groups         Export smart computer groups (JSON per group)
  --packages             Download actual .pkg/.dmg files from JCDS
  --blueprints           Export blueprints via Platform API (JSON per blueprint)
  --compliance           Export compliance benchmarks (JSON per benchmark)
  --computers            Export full computer inventory (single JSON file)
  --app-installers       Export app installer deployments (JSON per deployment)
  --output-dir <path>    Base output directory
                         Default: ~/Desktop/Jamf_Pro_Backup
                         Date subfolder YYYY_MM_DD is always appended.
  --log-file <path>      Full path for the log file
                         Default: <output-dir>/jamf_cli_logs.log
  -n, --dry-run          Preview all jamf-cli commands without executing them.
                         Lists what would be exported/downloaded but makes no changes.
  --classic-client-id    Client ID for Classic API access (required for --static-groups).
                         Create under: Jamf Pro → Settings → System → API Roles and Clients
  --classic-client-secret
                         Client secret for Classic API access (required for --static-groups).
  --help                 Show this help message

Environment variable overrides:
  JAMF_URL_OVERRIDE    Override Jamf Pro URL
  JAMF_TOKEN_OVERRIDE  Use a pre-obtained Bearer token

Output structure:
  <output-dir>/YYYY_MM_DD/policies/
  <output-dir>/YYYY_MM_DD/profiles/
  <output-dir>/YYYY_MM_DD/static_groups/      ← includes *_members.csv per group
  <output-dir>/YYYY_MM_DD/static_groups/_all_members.csv
  <output-dir>/YYYY_MM_DD/smart_groups/
  <output-dir>/YYYY_MM_DD/packages/
  <output-dir>/YYYY_MM_DD/blueprints/
  <output-dir>/YYYY_MM_DD/compliance/
  <output-dir>/YYYY_MM_DD/computers/
  <output-dir>/YYYY_MM_DD/app_installer_deployments/

Log:
  <output-dir>/jamf_cli_logs.log

Requirements:
  jamf-cli installed and configured.
  Install: https://github.com/Jamf-Concepts/jamf-cli
  Setup:   https://github.com/Jamf-Concepts/jamf-cli/wiki/Setup-Guide
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
        -n|--dry-run)
            DRY_RUN=true
            ;;
        --classic-client-id)
            (( i++ ))
            CLASSIC_CLIENT_ID="${args[$i]}"
            ;;
        --classic-client-id=*)
            CLASSIC_CLIENT_ID="${arg#--classic-client-id=}"
            ;;
        --classic-client-secret)
            (( i++ ))
            CLASSIC_CLIENT_SECRET="${args[$i]}"
            ;;
        --classic-client-secret=*)
            CLASSIC_CLIENT_SECRET="${arg#--classic-client-secret=}"
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

[[ -n "$custom_output_dir" ]] && OUTPUT_BASE="$custom_output_dir"
OUTPUT_DIR="${OUTPUT_BASE}/${currentYear}_${currentMonth}_${currentDate}"
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
    updateScriptLog "DRY-RUN MODE — jamf-cli commands will be shown but not executed"
    updateScriptLog "  OUTPUT_DIR : $OUTPUT_DIR"
    updateScriptLog "  scriptLog  : $scriptLog"
    updateScriptLog "  jamf-cli   : $(which jamf-cli 2>/dev/null)"
    updateScriptLog "  version    : $(jamf-cli version 2>/dev/null | head -1)"
    updateScriptLog "  profile    : $(jamf-cli config list 2>/dev/null | tr -d '\n' | head -c 200)"
fi

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
else
    $run_policies   && policies
    $run_profiles   && profiles
    $run_static     && staticGroups
    $run_smart      && smartGroups
    $run_packages   && packages
    $run_blueprints         && blueprints
    $run_compliance         && compliance
    $run_computers          && computers
    $run_app_installers     && appInstallerDeployments
fi

updateScriptLog "=== Backup complete → $OUTPUT_DIR ==="