#!/usr/bin/env python3
import sys
import requests
import time

# --- Get Access Token (converted from bash function) ---
def get_access_token(jamf_url, client_id, client_secret):
    """
    Request a new access token from Jamf Pro using OAuth client credentials.
    Returns (access_token, expiration_epoch).
    """
    token_url = f"{jamf_url}/api/oauth/token"
    headers = {"Content-Type": "application/x-www-form-urlencoded"}
    data = {
        "grant_type": "client_credentials",
        "client_id": client_id,
        "client_secret": client_secret
    }

    resp = requests.post(token_url, headers=headers, data=data)
    if resp.status_code != 200:
        raise Exception(f"Failed to get token: {resp.status_code} {resp.text}")

    token_data = resp.json()
    access_token = token_data["access_token"]
    expires_in = int(token_data["expires_in"])
    expiration_epoch = int(time.time()) + expires_in - 1

    return access_token, expiration_epoch

# --- Main script ---
def main():
    if len(sys.argv) != 5:
        print("Usage: python script.py <jamf_url> <client_id> <client_secret> <group_id>")
        sys.exit(1)

    jamf_url = sys.argv[1].rstrip("/")
    client_id = sys.argv[2]
    client_secret = sys.argv[3]
    group_id = sys.argv[4]

    # Get access token
    access_token, token_expiration_epoch = get_access_token(jamf_url, client_id, client_secret)
    headers = {"Authorization": f"Bearer {access_token}", "Accept": "application/json"}

    # --- Get all computer profiles ---
    profiles_url = f"{jamf_url}/api/v1/computer-profiles"
    resp = requests.get(profiles_url, headers=headers)

    if resp.status_code != 200:
        print("Failed to list profiles:", resp.text)
        sys.exit(1)

    profiles = resp.json().get("results", [])
    print(f"Found {len(profiles)} profiles")

    # --- Iterate through each profile and update ---
    for profile in profiles:
        profile_id = profile["id"]
        profile_url = f"{jamf_url}/api/v1/computer-profiles/{profile_id}"

        # Get full profile details
        detail_resp = requests.get(profile_url, headers=headers)
        if detail_resp.status_code != 200:
            print(f"❌ Failed to get profile {profile_id}: {detail_resp.text}")
            continue

        full_profile = detail_resp.json()

        # Get current exclusions
        exclusions = full_profile.get("scope", {}).get("exclusions", {}).get("computerGroups", [])

        # Skip if already excluded
        if any(str(g["id"]) == str(group_id) for g in exclusions):
            print(f"⚠️ Profile {profile_id} already has group {group_id} in exclusions.")
            continue

        # Add new exclusion
        exclusions.append({"id": group_id, "name": ""})
        full_profile["scope"]["exclusions"]["computerGroups"] = exclusions

        # Update profile
        update_resp = requests.put(
            profile_url,
            headers={**headers, "Content-Type": "application/json"},
            json=full_profile
        )

        if update_resp.status_code == 200:
            print(f"✅ Successfully updated profile {profile_id}")
        else:
            print(f"❌ Failed to update profile {profile_id}: {update_resp.text}")

    # --- Print token info ---
    print(f"\nAccess token expires at epoch: {token_expiration_epoch} ({time.ctime(token_expiration_epoch)})")

if __name__ == "__main__":
    main()
