#!/usr/bin/env python3

import csv
import sys
from datetime import date
from jamf_pro_sdk import JamfProClient, ApiClientCredentialsProvider
from jamf_pro_sdk.models.pro.computers import Computer

# --- Jamf Credentials ---
client_id = sys.argv[1]
client_secret = sys.argv[2]
api_url = sys.argv[3]
# --- Retrieve Jamf API Token ---
client = JamfProClient(
	server=api_url,
	credentials=ApiClientCredentialsProvider(client_id, client_secret)
)

mac_app_store = []
# --- Get List of Jamf Computers ---
jamfComputers = []
response = client.pro_api.get_computer_inventory_v1(sections=['APPLICATIONS'])
print()
for computer in response:
	applications = getattr(computer, "applications", [])
	for app in applications:
		app_name = getattr(app, "name", "Unknown")
		from_app_store = getattr(app, "macAppStore", "Unknown")
#		print(app_name, from_app_store)
		if from_app_store is True:
			mac_app_store.append(app_name)
app_store_list = set(mac_app_store)
print(len(app_store_list),app_store_list)