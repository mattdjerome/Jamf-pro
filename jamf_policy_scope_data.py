#!/usr/bin/env python3

import time
import requests
import sys
import csv
import getpass

# Get Current User
username = getpass.getuser()
# Variables
url = sys.argv[1]
client_id = sys.argv[2]
client_secret = sys.argv[3]

# Global Variables
access_token = ""
token_expiration_epoch = 0


def get_access_token():
    global access_token, token_expiration_epoch
    response = requests.post(f"{url}/api/oauth/token", data={
        "client_id": client_id,
        "client_secret": client_secret,
        "grant_type": "client_credentials"
    }, headers={"Content-Type": "application/x-www-form-urlencoded"})

    if response.status_code == 200:
        response_data = response.json()
        access_token = response_data.get("access_token")
        expires_in = response_data.get("expires_in")
        token_expiration_epoch = int(time.time()) + expires_in - 1
    else:
        print(f"Error getting token: {response.status_code} - {response.text}")
    return access_token


def check_token_expiration():
    if access_token:
        response = requests.get(
            f"{url}/api/v1/jamf-pro-version",
            headers={"Authorization": f"Bearer {access_token}"}
        )
        print(response.json())


def invalidate_token():
    global access_token, token_expiration_epoch
    response = requests.post(
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
        print(f"An unknown error occurred: {response.status_code} - {response.text}")


def retrieve_policy_data(base_url):
    response = requests.get(
        f"{base_url}/JSSResource/policies",
        headers={"accept": "application/json", "Authorization": f"Bearer {access_token}"}
    )
    return response.json()['policies']


def retrieve_policy_scope(policy_id, base_url):
    response = requests.get(
        f"{base_url}/JSSResource/policies/id/{policy_id}",
        headers={"accept": "application/json", "Authorization": f"Bearer {access_token}"}
    )
    if response.status_code != 200:
        print(f"  WARNING: Failed to retrieve policy {policy_id} (HTTP {response.status_code})")
        return None
    data = response.json()
    if 'policy' not in data:
        print(f"  WARNING: Policy {policy_id} returned unexpected structure: {data}")
        return None
    return data


def fmt(val):
    """
    Flatten a scope field to a pipe-separated string of names,
    or '0' if empty/missing.
    """
    if val is None:
        return '0'
    if isinstance(val, dict):
        # e.g. jss_users: {} — empty dict means no data
        return '0' if not val else '|'.join(str(v) for v in val.values())
    if isinstance(val, list):
        if not val:
            return '0'
        parts = []
        for item in val:
            if isinstance(item, dict):
                parts.append(item.get('name', str(item)))
            else:
                parts.append(str(item))
        return '|'.join(parts)
    return val if val != '' else '0'


# Main Execution
get_access_token()
check_token_expiration()
policy_data = retrieve_policy_data(url)

policies = {}
for entry in policy_data:
    policy = retrieve_policy_scope(entry['id'], url)
    if policy is None:
        print(f"  Skipping policy {entry['id']}")
        continue
    general = policy['policy']['general']
    scope = policy['policy']['scope']
    excl = scope.get('exclusions', {})
    lim = scope.get('limitations', {})

    if not general['enabled']:
        continue

    policies[entry['id']] = {
        # General
        'policy_name':                  general.get('name', '0'),
        'enabled':                      general.get('enabled', '0'),
        'trigger':                      general.get('trigger', '0'),
        'frequency':                    general.get('frequency', '0'),
        'category':                     general.get('category', {}).get('name', '0'),
        # Scope
        'all_computers':                scope.get('all_computers', '0'),
        'all_jss_users':                scope.get('all_jss_users', '0'),
        'computers':                    fmt(scope.get('computers')),
        'computer_groups':              fmt(scope.get('computer_groups')),
        'buildings':                    fmt(scope.get('buildings')),
        'departments':                  fmt(scope.get('departments')),
        'jss_users':                    fmt(scope.get('jss_users')),
        'jss_user_groups':              fmt(scope.get('jss_user_groups')),
        # Limitations
        'limitations_users':            fmt(lim.get('users')),
        'limitations_user_groups':      fmt(lim.get('user_groups')),
        'limitations_network_segments': fmt(lim.get('network_segments')),
        'limitations_ibeacons':         fmt(lim.get('ibeacons')),
        # Exclusions
        'exclusion_computers':          fmt(excl.get('computers')),
        'exclusion_computer_groups':    fmt(excl.get('computer_groups')),
        'exclusion_buildings':          fmt(excl.get('buildings')),
        'exclusion_departments':        fmt(excl.get('departments')),
        'exclusion_users':              fmt(excl.get('users')),
        'exclusion_user_groups':        fmt(excl.get('user_groups')),
        'exclusion_network_segments':   fmt(excl.get('network_segments')),
        'exclusion_jss_users':          fmt(excl.get('jss_users')),
        'exclusion_jss_user_groups':    fmt(excl.get('jss_user_groups')),
    }
    print(f"Processed policy {entry['id']}: {general['name']}")

invalidate_token()

fieldnames = [
    'policy_id', 'policy_name', 'enabled', 'trigger', 'frequency', 'category',
    'all_computers', 'all_jss_users',
    'computers', 'computer_groups', 'buildings', 'departments',
    'jss_users', 'jss_user_groups',
    'limitations_users', 'limitations_user_groups',
    'limitations_network_segments', 'limitations_ibeacons',
    'exclusion_computers', 'exclusion_computer_groups',
    'exclusion_buildings', 'exclusion_departments',
    'exclusion_users', 'exclusion_user_groups',
    'exclusion_network_segments', 'exclusion_jss_users', 'exclusion_jss_user_groups',
]

output_path = f'/Users/{username}/Desktop/policy_data.csv'
with open(output_path, 'w', newline='') as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    for policy_id, attrs in policies.items():
        writer.writerow({'policy_id': policy_id, **attrs})

print(f"\nDone! CSV saved to {output_path}")