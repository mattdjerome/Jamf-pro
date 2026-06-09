#!/usr/bin/env python3

import sys
from jamf_pro_sdk import JamfProClient, ApiClientCredentialsProvider
from datetime import datetime,date
import requests
import csv
import getpass

# -----------------------
# Variables get passed in the following order from your IDE or terminal
# 1. Jamf Pro URL (without https://) ex: org.jamfcloud.com
# 2. Jamf Pro Client ID
# 3. Jamf Pro Client Secret Key
# 4. Amount of days you want to check for not reporting
# 5. Output choice. Options are csv, terminal, both. This is not case sensitive and if 
# Documentation for the Jamf Pro Python SDK https://macadmins.github.io/jamf-pro-sdk-python/user/getting_started.html
# Documentation for Jamf Pro API Client Permissions/Roles https://learn.jamf.com/en-US/bundle/jamf-pro-documentation-current/page/API_Roles_and_Clients.html
# -----------------------


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
# Desired Destination For Data
# -----------------------
output = sys.argv[5]
if output.lower() != "csv" and output.lower() != "terminal" and output.lower() != "both":
	print("No valid output selected, variable 5 should be csv, terminal or both")
	sys.exit(1)
	
# -----------------------
# Retrieve Jamf Computers
# -----------------------
client = JamfProClient(jamf_hostname, ApiClientCredentialsProvider(jamf_client_id, jamf_secret_key))
computers = client.pro_api.get_computer_inventory_v1(sections=["GENERAL","HARDWARE","USER_AND_LOCATION"])

# -----------------------
# Find Days Since LastCheckin
# -----------------------
noCheckIn = [] # Get list of computers to see how many occur
timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
currentUser = getpass.getuser()
filename = f"/Users/{currentUser}/Desktop/macOS_no_check_in_last_{daysSince}_days_{timestamp}.csv"
# Opens/Creates a CSV file in case it's needed
# MATT...convert writing to csv and/or terminal to functions so it doesn't create a file that's not needed.



with open(filename, mode="w", newline="", encoding="utf-8") as csv_file:
	if output.lower() == "both" or output.lower() == "csv":
		writer = csv.writer(csv_file)
		writer.writerow(["JSS ID", "Hostname", "Serial Number","Assigned User","Days Since Last Checkin"])
	# Starts to cycle through all the data and write to the desired output
	for macs in computers:
		try:
			lastContact = macs.general.lastContactTime
			lastCheckin = datetime.fromisoformat(f"{lastContact}")
			year = lastCheckin.year
			month = lastCheckin.month
			day = lastCheckin.day
			today = date.today()
			lastCheckinDate = date(year, month, day)
			date_difference = today - lastCheckinDate
			if date_difference.days > daysSince:
				noCheckIn.append(macs.general.name)
				if output.lower() == "csv" or output.lower() == "both":
					writer = csv.writer(csv_file)
					writer.writerow([macs.id ,macs.general.name,macs.hardware.serialNumber, macs.userAndLocation.username, date_difference.days])
				if output.lower() == "both" or output.lower() == "terminal":
					print(macs.id ,macs.general.name,macs.hardware.serialNumber, macs.userAndLocation.username, date_difference.days)
		except:
			continue
	if output.lower() == "both" or output.lower() == "csv":
		writer.writerow([f"{len(noCheckIn)} macs detected"])
	if output.lower() == "terminal" or output.lower() == "both":
		print(f"{len(noCheckIn)} macs detected")
print("Operation Complete")