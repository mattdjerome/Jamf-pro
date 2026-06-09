#!/usr/bin/env python3

import sys
from jamf_pro_sdk import JamfProClient, ApiClientCredentialsProvider
from datetime import datetime,date
import requests
import getpass
import csv

# -----------------------
# Jamf API Credentials
# -----------------------
jamf_hostname = sys.argv[1]
jamf_client_id = sys.argv[2]
jamf_secret_key = sys.argv[3]


# -----------------------
# Days Since LastCheckin
# -----------------------

daysSince = int(sys.argv[4])

# -----------------------
# Retrieve Jamf Computers
# -----------------------

client = JamfProClient(jamf_hostname, ApiClientCredentialsProvider(jamf_client_id, jamf_secret_key))
computers = client.pro_api.get_computer_inventory_v1(sections=["GENERAL","HARDWARE","USER_AND_LOCATION"])
#
## -----------------------
## Retrieve Jamf API Token
## -----------------------

access_token = client.get_access_token() # returns a JSON
access_token = access_token.token # gets just the token


# -----------------------
# Create Do Not Delete List i.e. legal hold, missing, etc
# -----------------------

doNotDelete = [] # adds computers where the do not delete EA is enabled.
for macs in computers:
	computerName = macs.general.name
	managementID = macs.id
	for ea in macs.general.extensionAttributes:
		if ea.name == "Do Not Delete" and ea.values:
			doNotDelete.append(macs.id)

			# -----------------------
			# Find Days Since Last Checkin and write to CSV if needed
			# -----------------------
timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
currentUser = getpass.getuser()
filename = f"/Users/{currentUser}/Desktop/jamf_pro_no_checkin_{daysSince}_days_{timestamp}.csv"

DaysSinceCheckin = [] # Get list of computers to see how many occur
jamfID = []
with open(filename, mode="x", newline="", encoding="utf-8") as csv_file:
	writer = csv.writer(csv_file)
	writer.writerow(["JSS ID", "Hostname", "Serial Number","Assigned User","Days Since Last Checkin", "Recovery Key"]) #row header
	for macs in computers:
		if macs.general.lastContactTime is not None and macs.general.lastContactTime != "None":
			lastCheckin = datetime.fromisoformat(f"{macs.general.lastContactTime}")
			today = date.today()
			lastCheckinDate = date(lastCheckin.year, lastCheckin.month, lastCheckin.day)
			date_difference = today - lastCheckinDate
			if date_difference.days >= daysSince and macs.general.name not in doNotDelete:
				DaysSinceCheckin.append(macs.general.name)
				key_url = f"https://{jamf_hostname}/api/v2/computers-inventory/{macs.id}/filevault"
				headers = {"accept": "application/json",'Authorization': f'Bearer {access_token}',}
				response = requests.get(key_url, headers=headers)
				result = response.json()
				if response.status_code == 404:
					key = "No Key Present"
				else:
					key = result['personalRecoveryKey']
					writer.writerow([macs.id, macs.general.name, macs.hardware.serialNumber, macs.userAndLocation.username, date_difference, key])
						
# -----------------------
# Delete Computer Record Function
# -----------------------
