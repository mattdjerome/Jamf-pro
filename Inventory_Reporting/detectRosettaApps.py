#!/usr/bin/env python3

import csv
import sys
from datetime import date
from jamf_pro_sdk import JamfProClient, ApiClientCredentialsProvider
from jamf_pro_sdk.models.pro.computers import Computer
from collections import Counter
import pandas as pd

# --- Jamf Credentials ---
client_id = sys.argv[1]
client_secret = sys.argv[2]
api_url = sys.argv[3]
# --- Retrieve Jamf API Token ---
client = JamfProClient(
	server=api_url,
	credentials=ApiClientCredentialsProvider(client_id, client_secret)
)

rosetta_apps = []
# --- Get List of Jamf Computers ---
jamfComputers = []
response = client.pro_api.get_computer_inventory_v1(sections=['HARDWARE','OPERATING_SYSTEM','EXTENSION_ATTRIBUTES'])
print("")
for apps in response:
    if apps.hardware.processorType is not None and 'Apple' in apps.hardware.processorType:
        for dID in apps.extensionAttributes:
            if dID.name == "Rosetta Required Apps" and dID != "" and dID.name != 'No Rosetta Apps Detected':
                length = 0
                while length < len(dID.values):
                    app_name = f"{dID.values[length]}".split('\n')
                    rosetta_apps.extend(app_name)
                    length += 1
rosetta_apps.remove("No Rosetta Apps Detected")
rosetta_apps.remove('Uninstall Product')
counts = pd.Series(rosetta_apps)
no_dupes = set(rosetta_apps)
for app in no_dupes:
    if app != "":
        print(f"{app}, {rosetta_apps.count(app)}")