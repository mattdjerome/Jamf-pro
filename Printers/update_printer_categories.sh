#!/bin/bash
# update_printer_category_and_policy_icon.sh
# For each printer name in the CSV:
#   1. Updates the printer's category in Jamf
#   2. Finds a policy named "Wincraft - <printer name>" and sets its Self Service icon
#
# CSV format: one printer name per line, no header
# Usage: ./script.sh CLIENT_ID CLIENT_SECRET /path/to/printers.csv "Category Name" https://jamf.example.com

# ── Configuration ────────────────────────────────────────────────────────────
JAMF_URL="$5"           # No trailing slash
CLIENT_ID="$1"
CLIENT_SECRET="$2"
CSV_FILE="$3"           # Path to your CSV file
NEW_CATEGORY="$4"       # Category to apply to all printers
ICON_ID="1945"          # Jamf internal icon ID for "Prefs_Printer .png"

# ── Validate CSV exists ───────────────────────────────────────────────────────
if [[ ! -f "$CSV_FILE" ]]; then
    echo "ERROR: CSV file not found at '${CSV_FILE}'"
    exit 1
fi

# ── Get Bearer Token via OAuth Client Credentials ────────────────────────────
echo "Authenticating..."
token_response=$(curl -s -X POST \
    "${JAMF_URL}/api/oauth/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}")

TOKEN=$(echo "$token_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

if [[ -z "$TOKEN" ]]; then
    echo "ERROR: Failed to obtain bearer token. Check client credentials and URL."
    echo "Response: $token_response"
    exit 1
fi
echo "Token acquired."
echo ""

# ── Counters ──────────────────────────────────────────────────────────────────
printer_success=0
printer_failed=0
policy_success=0
policy_failed=0

# ── Process each row in the CSV ───────────────────────────────────────────────
while IFS= read -r printer_name || [[ -n "$printer_name" ]]; do
    # Skip empty lines and comment lines
    [[ -z "$printer_name" || "$printer_name" == \#* ]] && continue

    # Trim whitespace
    printer_name=$(echo "$printer_name" | xargs)

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Processing: '${printer_name}'"

    # ── 1. Update Printer Category ──────────────────────────────────────────
    encoded_name=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$printer_name")
    printer_xml=$(curl -s -X GET \
        "${JAMF_URL}/JSSResource/printers/name/${encoded_name}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Accept: application/xml")

    printer_id=$(echo "$printer_xml" | grep -o '<id>[0-9]*</id>' | head -1 | grep -o '[0-9]*')

    if [[ -z "$printer_id" ]]; then
        echo "  [Printer] ✗ FAILED — not found in Jamf: '${printer_name}'"
        ((printer_failed++))
    else
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
            "${JAMF_URL}/JSSResource/printers/id/${printer_id}" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/xml" \
            -d "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<printer>
    <category>${NEW_CATEGORY}</category>
</printer>")

        if [[ "$http_code" == "201" ]]; then
            echo "  [Printer] ✓ Category updated (ID: ${printer_id}, HTTP ${http_code})"
            ((printer_success++))
        else
            echo "  [Printer] ✗ FAILED to update category (ID: ${printer_id}, HTTP ${http_code})"
            ((printer_failed++))
        fi
    fi

    # ── 2. Update Matching Policy Self Service Icon ─────────────────────────
    policy_name="Wincraft - ${printer_name}"
    encoded_policy_name=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$policy_name")

    policy_xml=$(curl -s -X GET \
        "${JAMF_URL}/JSSResource/policies/name/${encoded_policy_name}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Accept: application/xml")

    policy_id=$(echo "$policy_xml" | grep -o '<id>[0-9]*</id>' | head -1 | grep -o '[0-9]*')

    if [[ -z "$policy_id" ]]; then
        echo "  [Policy]  ✗ FAILED — policy not found: '${policy_name}'"
        ((policy_failed++))
    else
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
            "${JAMF_URL}/JSSResource/policies/id/${policy_id}" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/xml" \
            -d "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<policy>
    <self_service>
        <self_service_icon>
            <id>${ICON_ID}</id>
        </self_service_icon>
    </self_service>
</policy>")

        if [[ "$http_code" == "201" ]]; then
            echo "  [Policy]  ✓ Icon updated (ID: ${policy_id}, HTTP ${http_code})"
            ((policy_success++))
        else
            echo "  [Policy]  ✗ FAILED to update icon (ID: ${policy_id}, HTTP ${http_code})"
            ((policy_failed++))
        fi
    fi

done < "$CSV_FILE"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  Printers: ✓ ${printer_success} updated, ✗ ${printer_failed} failed"
echo "  Policies: ✓ ${policy_success} updated, ✗ ${policy_failed} failed"
echo "════════════════════════════════════════"

# ── Revoke token ──────────────────────────────────────────────────────────────
echo "Revoking token..."
curl -s -X POST \
    "${JAMF_URL}/api/oauth/revoke" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "token=${TOKEN}&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}"

echo "Done."