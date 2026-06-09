#!/usr/bin/env python3
from jamf_pro_sdk import JamfProClient, ApiClientCredentialsProvider
import csv
import argparse
from datetime import datetime
import getpass
import requests
import json
import sys

def get_uapi_token(domain, client_id, client_secret):

    url = f"https://{domain}/api/v1/oauth/token"
    
    payload = {
        "grant_type": "client_credentials",
        "client_id": f"{client_id}",
        "client_secret": f"{client_secret}"
    }
    headers = {
        "accept": "application/json",
        "content-type": "application/x-www-form-urlencoded"
    }
    
    response = requests.post(url, data=payload, headers=headers)
    result = response.json()
    return result['access_token']

def invalidate_uapi_token(domain, uapi_token):

    jamf_test_url = "https://" + domain + "/api/v1/auth/invalidate-token"
    headers = {'Accept': '*/*', 'Authorization': 'Bearer ' + uapi_token}
    response = requests.post(url=jamf_test_url, headers=headers)

    if response.status_code == 204:
        print('Token invalidated!')
    else:
        print('Error invalidating token.')

def get_computer_data(domain, client_id, client_secret):
    
    client = JamfProClient(domain, ApiClientCredentialsProvider(client_id, client_secret))
    computers = client.pro_api.get_computer_inventory_v1(sections=["GENERAL","PURCHASING"])
    return computers

def main():
    jamf_hostname = sys.argv[1]
    jamf_clientID = sys.argv[2]
    jamf_clientSecret= sys.argv[3]
    # fetch Jamf Pro (ex-universal) api token
    uapi_token = get_uapi_token(jamf_hostname, jamf_clientID, jamf_clientSecret)

    # fetch Jamf Computer data
    jamf_computer_data = get_computer_data(jamf_hostname, jamf_clientID, jamf_clientSecret)
    # invalidating token
    print('invalidating token...')
    invalidate_uapi_token(jamf_hostname, uapi_token)


if __name__ == '__main__':
    main()