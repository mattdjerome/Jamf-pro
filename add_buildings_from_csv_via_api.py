
#!/usr/bin/env python3
"""
jamf_add_buildings.py
─────────────────────
Reads building names from a CSV file and adds any that are missing
to the Buildings section of Jamf Pro via the Jamf Pro API.

Authentication: API Client (Client ID + Secret → OAuth2 client_credentials)

Usage
─────
  python3 jamf_add_buildings.py <url> <client_id> <client_secret> <csv_file> [column_name]

  url           Jamf Pro base URL, e.g. https://yourorg.jamfcloud.com
  client_id     API Client ID
  client_secret API Client Secret
  csv_file      Path to the CSV file
  column_name   (optional) Column containing building names; defaults to first column

Example
───────
  python3 jamf_add_buildings.py \
      https://yourorg.jamfcloud.com \
      abc123 xyz789 \
      buildings.csv "Building Name"

CSV format
──────────
Your CSV needs at least one column containing building names, e.g.:

  Building Name,City,Notes
  Headquarters,New York,Main office
  Building A,Chicago,
  Warehouse 1,Dallas,

Use --column "Building Name" to tell the script which column to read.
If --column is omitted, the first column is used.
"""

import csv
import logging
import sys
from pathlib import Path

try:
    import requests
except ImportError:
    sys.exit("❌  'requests' is not installed.  Run:  pip install requests")


# ─── Logging ──────────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("jamf-buildings")


# ─── Authentication ───────────────────────────────────────────────────────────

def get_bearer_token(session: requests.Session, base_url: str,
                     client_id: str, client_secret: str) -> str:
    """Obtain a Bearer token via OAuth2 client_credentials grant."""
    url = f"{base_url}/api/oauth/token"
    # Jamf requires Content-Type: application/x-www-form-urlencoded (sent by data=)
    # and does NOT want the session-level application/json Content-Type header here.
    resp = session.post(
        url,
        data={
            "grant_type": "client_credentials",
            "client_id": client_id,
            "client_secret": client_secret,
        },
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        timeout=15,
    )
    if not resp.ok:
        sys.exit(
            f"❌  Authentication failed: HTTP {resp.status_code}\n"
            f"    URL    : {url}\n"
            f"    Detail : {resp.text}\n"
            f"\n"
            f"    Check that:\n"
            f"      • The Client ID and Secret are correct (no extra spaces)\n"
            f"      • The API Client is enabled in Jamf Pro\n"
            f"      • The API Client has the 'Jamf Pro Server Objects > Buildings' privilege"
        )
    token = resp.json().get("access_token")
    if not token:
        sys.exit(f"❌  No access_token in response: {resp.text}")
    log.info("✅  Authenticated via API Client (OAuth2).")
    return token


# ─── Jamf API ─────────────────────────────────────────────────────────────────

def get_existing_buildings(session: requests.Session, base_url: str) -> dict:
    """
    Return {building_name_lower: building_id} for every building already in Jamf.
    Handles pagination automatically.
    """
    buildings = {}
    page, page_size = 0, 100

    while True:
        resp = session.get(
            f"{base_url}/api/v1/buildings",
            params={"page": page, "page-size": page_size},
            timeout=15,
        )
        resp.raise_for_status()
        data = resp.json()
        results = data.get("results", [])

        for b in results:
            buildings[b["name"].strip().lower()] = b["id"]

        if (page + 1) * page_size >= data.get("totalCount", 0) or not results:
            break
        page += 1

    log.info("📋  Found %d existing building(s) in Jamf Pro.", len(buildings))
    return buildings


def add_building(session: requests.Session, base_url: str, name: str) -> bool:
    """POST a new building. Returns True on success."""
    resp = session.post(
        f"{base_url}/api/v1/buildings",
        json={"name": name},
        timeout=15,
    )
    if resp.status_code in (200, 201):
        log.info("  ✅  Added : %s", name)
        return True
    log.error("  ❌  Failed to add '%s': HTTP %s – %s", name, resp.status_code, resp.text)
    return False


# ─── CSV input ────────────────────────────────────────────────────────────────

def read_buildings_from_csv(path: Path, column: str) -> list:
    """Extract building names from a CSV file."""
    with path.open(newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        headers = reader.fieldnames or []

        if not headers:
            sys.exit(f"❌  '{path}' appears to have no headers.")

        if column:
            if column not in headers:
                sys.exit(
                    f"❌  Column '{column}' not found.\n"
                    f"    Available columns: {headers}"
                )
            col = column
        else:
            col = headers[0]
            log.info("No column specified; using first column: '%s'", col)

        names = [
            row[col].strip()
            for row in reader
            if row.get(col, "").strip()
        ]

    log.info("📄  Read %d name(s) from '%s' (column: %s).", len(names), path, col)
    return names


# ─── Main ─────────────────────────────────────────────────────────────────────

USAGE = (
    "Usage: python3 jamf_add_buildings.py "
    "<url> <client_id> <client_secret> <csv_file> [column_name]"
)


def main() -> None:
    # sys.argv: [script, url, client_id, client_secret, csv_file, (column)]
    if len(sys.argv) < 5:
        sys.exit(f"❌  Too few arguments.\n{USAGE}")

    base_url      = sys.argv[1].rstrip("/")
    client_id     = sys.argv[2]
    client_secret = sys.argv[3]
    input_path    = Path(sys.argv[4])
    column        = sys.argv[5] if len(sys.argv) >= 6 else None

    if not input_path.exists():
        sys.exit(f"❌  File not found: {input_path}")

    # Read CSV
    desired = read_buildings_from_csv(input_path, column)
    if not desired:
        sys.exit("⚠️   No building names found in the CSV. Nothing to do.")

    # Deduplicate (case-insensitive), preserving first-occurrence order
    seen = set()
    unique = []
    for name in desired:
        if name.lower() not in seen:
            seen.add(name.lower())
            unique.append(name)

    dupes = len(desired) - len(unique)
    if dupes:
        log.info("ℹ️   Removed %d duplicate(s) from CSV input.", dupes)

    # Authenticate
    session = requests.Session()
    session.headers.update({"Accept": "application/json", "Content-Type": "application/json"})
    token = get_bearer_token(session, base_url, client_id, client_secret)
    session.headers["Authorization"] = f"Bearer {token}"

    # Fetch what's already in Jamf
    existing = get_existing_buildings(session, base_url)

    # Diff
    to_add = [n for n in unique if n.lower() not in existing]
    already_present = len(unique) - len(to_add)

    log.info("📊  %d already present, %d to add.", already_present, len(to_add))

    if not to_add:
        print("\n🎉  All buildings are already in Jamf Pro. Nothing to do.")
        return

    # Add missing buildings
    print()
    added, failed = 0, 0
    for name in to_add:
        if add_building(session, base_url, name):
            added += 1
        else:
            failed += 1

    # Summary
    print()
    print("─" * 46)
    print(f"  Already present  : {already_present}")
    print(f"  Added            : {added}")
    print(f"  Failed           : {failed}")
    print("─" * 46)

    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
