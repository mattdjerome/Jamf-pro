#!/usr/bin/env python3
import sys
import csv
from jamf_pro_sdk import JamfProClient, ApiClientCredentialsProvider
from datetime import datetime
import getpass

# Retrieve command line arguments
jamf_hostname = sys.argv[1]
jamf_client_id = sys.argv[2]
jamf_secret_key = sys.argv[3]

# Get current user to save to desktop
currentUser = getpass.getuser()

# Create filename with timestamp
timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
filename = f"/Users/{currentUser}/Desktop/user_admin_report{timestamp}.csv"

# Generate Access with API Credentials
client = JamfProClient(jamf_hostname, ApiClientCredentialsProvider(jamf_client_id,jamf_secret_key))

response = client.pro_api.get_computer_inventory_v1(sections=["GENERAL", "HARDWARE", "USER_AND_LOCATION","LOCAL_USER_ACCOUNTS"])


with open(filename, mode="w", newline="", encoding="utf-8") as csv_file:
	writer = csv.writer(csv_file)
	writer.writerow(["Computer Name", "Computer Serial Number", "Assigned User", "Assigned User Email","User Account", "Is Admin"])
	for computer in response:
		computerName = computer.general.name
		print(computer.general.name)
		if computerName.startswith("DEP"):
			continue	
		for acct in computer.localUserAccounts:
			if acct.username != "itsupport" and acct.username != "Jamf-admin":
				writer.writerow([computerName, computer.hardware.serialNumber, computer.userAndLocation.realname, computer.userAndLocation.email, acct.username,acct.admin])
		
		
		
		
#with open(filename, mode="w", newline="", encoding="utf-8") as csv_file:
#	writer = csv.writer(csv_file)
#	writer.writerow(["Application Name", "Count"])