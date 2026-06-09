#!/usr/bin/env python3
"""
Add/update restricted software entries in Jamf Pro from a CSV file.

Usage:
    python jamf_add_restricted_from_csv.py \
        --csv restricted_software.csv \
        --base-url https://jamf.example.com \
        --username api_user \
        --password secret_password

CSV example (header row):
name,developer,version,match_type,description
ExampleApp,ExampleCorp,1.2.3,Exact,Added via CSV
AnotherApp,AnotherCorp,,Contains,Block any matching name
"""

import argparse
import csv
import sys
import requests
import xml.etree.ElementTree as ET
from typing import Optional

# === Configurable endpoint path ===
# If your Jamf requires a different prefix (e.g. /JSSResource), update ENDPOINT_PATH.
ENDPOINT_PATH = "/updaterestrictedsoftwarebyname"
TOKEN_PATH = "/api/v1/auth/token"
# ================================


def get_api_token(base_url: str, username: str, password: str, timeout: float = 10.0) -> Optional[str]:
    """Try to get a Jamf API token. Return token string or None on failure."""
    token_url = base_url.rstrip("/") + TOKEN_PATH
    try:
        resp = requests.post(token_url, auth=(username, password), timeout=timeout)
        resp.raise_for_status()
        data = resp.json()
        token = data.get("token") or data.get("access_token")  # tolerate variations
        if not token:
            print("[WARN] Token endpoint returned no 'token' field; falling back to Basic auth", file=sys.stderr)
        return token
    except requests.RequestException as e:
        print(f"[WARN] Unable to fetch token (falling back to Basic auth): {e}", file=sys.stderr)
        return None


def row_to_xml(row: dict) -> str:
    """
    Build XML from a CSV row dict. Only includes elements that are non-empty.
    Modify element names if your Jamf schema differs.
    """
    root = ET.Element("restricted_software")

    # Map CSV columns to XML child elements we expect. Change or extend as needed.
    fields = ["name", "developer", "version", "match_type", "description"]
    for f in fields:
        value = (row.get(f) or "").strip()
        # Only add element if there's a value (Jamf may accept empty tags, but safer to omit)
        if value != "":
            child = ET.SubElement(root, f)
            child.text = value

    # Produce a UTF-8 encoded string
    xml_bytes = ET.tostring(root, encoding="utf-8")
    return xml_bytes.decode("utf-8")


def post_restricted_software(base_url: str, endpoint: str, xml_body: str,
                             token: Optional[str], username: str, password: str,
                             verify_tls: bool = True, timeout: float = 15.0) -> requests.Response:
    """
    POST the XML payload to Jamf. Uses Bearer token if provided, otherwise Basic Auth.
    """
    url = base_url.rstrip("/") + endpoint
    headers = {
        "Accept": "application/json, text/xml, application/xml",
        "Content-Type": "application/xml; charset=utf-8"
    }
    auth = None
    if token:
        headers["Authorization"] = f"Bearer {token}"
    else:
        auth = (username, password)

    resp = requests.post(url, data=xml_body.encode("utf-8"), headers=headers, auth=auth, timeout=timeout, verify=verify_tls)
    return resp


def process_csv(csv_path: str, base_url: str, username: str, password: str,
                endpoint: str = ENDPOINT_PATH, verify_tls: bool = True):
    token = get_api_token(base_url, username, password)
    success = 0
    fail = 0

    with open(csv_path, newline='', encoding='utf-8') as csvfile:
        reader = csv.DictReader(csvfile)
        if reader.fieldnames is None:
            print("CSV appears empty or missing header row.", file=sys.stderr)
            return

        print(f"Found CSV columns: {reader.fieldnames}")
        for i, row in enumerate(reader, start=1):
            # Build XML payload for this row
            xml_payload = row_to_xml(row)
            print(f"\n--- Row {i}: sending restricted software '{row.get('name')}' ---")
            print(xml_payload)  # optional: comment out if you don't want to print payloads

            try:
                resp = post_restricted_software(base_url, endpoint, xml_payload, token, username, password, verify_tls)
                # Consider 200/201/204 as success depending on Jamf response convention
                if resp.status_code in (200, 201, 204):
                    print(f"[OK] Row {i} succeeded: {resp.status_code}")
                    # optionally print JSON or text response
                    content_type = resp.headers.get("Content-Type", "")
                    if "application/json" in content_type:
                        try:
                            print(resp.json())
                        except ValueError:
                            print(resp.text)
                    else:
                        if resp.text:
                            print("Response text:", resp.text)
                    success += 1
                else:
                    print(f"[ERROR] Row {i} failed: HTTP {resp.status_code}", file=sys.stderr)
                    print(resp.text, file=sys.stderr)
                    fail += 1
            except requests.RequestException as e:
                print(f"[EXCEPT] Row {i} request error: {e}", file=sys.stderr)
                fail += 1

    print(f"\nFinished. Success: {success}, Failed: {fail}")


def main():
    parser = argparse.ArgumentParser(description="Add/update restricted software entries in Jamf Pro from CSV")
    parser.add_argument("--csv", required=True, help="Path to CSV file")
    parser.add_argument("--base-url", required=True, help="Jamf base URL, e.g. https://jamf.example.com")
    parser.add_argument("--username", required=True, help="API username")
    parser.add_argument("--password", required=True, help="API password")
    parser.add_argument("--endpoint", default=ENDPOINT_PATH, help="Endpoint path (default: %(default)s)")
    parser.add_argument("--insecure", action="store_true", help="Disable TLS verification (not recommended)")
    args = parser.parse_args()

    process_csv(args.csv, args.base_url, args.username, args.password, endpoint=args.endpoint, verify_tls=not args.insecure)


if __name__ == "__main__":
    main()
