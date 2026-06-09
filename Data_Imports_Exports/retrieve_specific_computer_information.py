#!/usr/bin/env python3
import argparse
from jamf_pro_sdk import JamfProClient, ApiClientCredentialsProvider

# -----------------------
# Jamf API Credentials
# -----------------------
parser = argparse.ArgumentParser()
parser.add_argument("-j","--jamfProURL", type=str, help="Your Jamf Pro URL")
parser.add_argument("-cid","--clientId", type=str, help="Jamf Pro Client ID")
parser.add_argument("-cs","--clientSecret", type=str, help="Jamf Pro Client Secret")
args = parser.parse_args()

client = JamfProClient(args.jamfProURL, ApiClientCredentialsProvider(args.clientId, args.clientSecret))
computers = client.pro_api.get_computer_inventory_v1(sections=["GENERAL","HARDWARE","USER_AND_LOCATION"])

def retrieve_serial_numbers(jamf_data):
	jamfComputers = []
	for endpoint in jamf_data:
		jamfComputers.append(endpoint.hardware.serialNumber)
	return jamfComputers
print(retrieve_serial_numbers(computers))
