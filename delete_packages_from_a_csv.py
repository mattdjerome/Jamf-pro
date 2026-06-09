#!/usr/bin/env python3

import argparse
import sys
import time
import pandas as pd
import requests
import os


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Variables to access the Jamf Pro Tenant.")
    parser.add_argument("--url", default=os.getenv("url"), help="Jamf Pro base URL (no trailing slash)")
    parser.add_argument("--clientid", default=os.getenv("client_id"), help="Jamf Pro client id")
    parser.add_argument("--clientsecret", default=os.getenv("client_secret"), help="Jamf Pro client secret")
    parser.add_argument("--dry-run", action="store_true", help="Preview changes without writing to Jamf")
    parser.add_argument("--tenantid", help="tenant ID from account.jamf.com integrations")
    parser.add_argument("--csv",required=True, help="Path to the unused packages CSV report")
    return parser.parse_args()  # FIX: was missing return


# Global token state
access_token = ""
token_expiration_epoch = 0


def get_access_token(url, client_id, client_secret):
    global access_token, token_expiration_epoch
    response = requests.post(  # FIX: was formatted as a broken markdown hyperlink
        f"{url}/api/oauth/token",
        data={
            "client_id": client_id,
            "client_secret": client_secret,
            "grant_type": "client_credentials"
        },
        headers={"Content-Type": "application/x-www-form-urlencoded"}
    )

    if response.status_code == 200:
        response_data = response.json()
        access_token = response_data.get("access_token")
        expires_in = response_data.get("expires_in")
        current_epoch = int(time.time())  # FIX: `time` is now imported
        token_expiration_epoch = current_epoch + expires_in - 1
    else:
        print(f"Error getting token: {response.status_code} - {response.text}")
        sys.exit(1)

    return access_token


def invalidate_token(url):  # FIX: accept url as parameter instead of using undefined global
    global access_token, token_expiration_epoch
    response = requests.post(  # FIX: was formatted as a broken markdown hyperlink
        f"{url}/api/v1/auth/invalidate-token",
        headers={"Authorization": f"Bearer {access_token}"}
    )

    if response.status_code == 204:
        print("Token successfully invalidated")
        access_token = ""
        token_expiration_epoch = 0
    elif response.status_code == 401:
        print("Token already invalid")
    else:
        print(f"An unknown error occurred invalidating the token: {response.status_code} - {response.text}")


def main():
    args = parse_args()

    # FIX: validate args before doing anything else (was after get_access_token call)
    if not args.url:
        sys.exit("❌  Jamf URL is required (--url).")
    if not args.clientid:
        sys.exit("❌  Client ID is required (--clientid).")
    if not args.clientsecret:
        sys.exit("❌  Client Secret is required (--clientsecret).")
    if not args.tenantid:
        sys.exit("❌  Tenant ID is required (--tenantid).")
    if not args.csv:
        sys.exit("❌  CSV File is required (--csv).")
    # FIX: CSV path is now a CLI arg instead of hardcoded
    df = pd.read_csv(args.csv)
    package_ids = df['Package ID'].tolist()

    get_access_token(args.url, args.clientid, args.clientsecret)  # FIX: args.clientid (not args.client_id)

    for pkg_id in package_ids:
        delete_url = f"https://us.apigw.jamf.com/api/pro/v1/tenant/{args.tenantid}/packages/{pkg_id}"  # FIX: args.tenantid (was undefined tenantID)
        if args.dry_run:
            print(f"DRY-RUN ENABLED: Would delete Package ID {pkg_id} — {delete_url}")
            continue  # FIX: was missing continue, so dry-run fell through to the else branch
        else:
            print(f"Deleting Package ID {pkg_id}")
            response = requests.delete(delete_url, headers={"Authorization": f"Bearer {access_token}"})
            if response.status_code == 204:
                print(f"✅ Package {pkg_id} deleted.")
            else:
                print(f"❌ Failed to delete {pkg_id}: {response.status_code} - {response.text}")

    invalidate_token(args.url)  # FIX: pass url explicitly


if __name__ == "__main__":
    main()