##!/usr/bin/python3
#
#from jamf_pro_sdk.clients.pro_api.pagination import SortField
#import json
#import sys
#from jamf_pro_sdk import JamfProClient, ApiClientCredentialsProvider
#
## Initialize the Jamf Pro client
#client = JamfProClient(
#	server="fanatics.jamfcloud.com",
#	credentials=ApiClientCredentialsProvider(sys.argv[1], sys.argv[2])
#)
#
## Get a generator of paginated results
#response = client.pro_api.get_computer_inventory_v1(
#	sections=["GENERAL", "SOFTWARE_UPDATES", "OPERATING_SYSTEM"],
#	return_generator=True
#)
#count = 0
## Iterate through each page
#for page in response:
#	for computer in page.results:
#		# Safely handle possible None values
#		name = computer.general.name if computer.general else "Unknown"
#		asset_tag = computer.general.assetTag if computer.general else "None"
#
#		
#		# Check for software updates
#		if computer.softwareUpdates:
#			for update in computer.softwareUpdates:
#				if "macOS Sequoia" in update.name and computer.operatingSystem.version != "15.7" and computer.operatingSystem.version != "15.7.1" and computer.operatingSystem.version != "15.7.0":
#					print(f"Name: {name}, JSS ID: {computer.id}, Asset Tag: {asset_tag}, Current OS: {computer.operatingSystem.version}")
#					print(f"  Last Checkin     : {computer.general.lastContactTime}")
#					print(f"  Update Name      : {update.name}")
#					print(f"  Package Name     : {update.packageName}")
#					print(f"  Version          : {update.version}")
#					count = count + 1
#print(count)

#!/usr/bin/python3

import csv
from datetime import datetime
import sys
from jamf_pro_sdk import JamfProClient, ApiClientCredentialsProvider

# Timestamp for filename
timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
filename = f"macOS_Sequoia_Eligible_{timestamp}.csv"

# Initialize the Jamf Pro client
client = JamfProClient(
	server="fanatics.jamfcloud.com",
	credentials=ApiClientCredentialsProvider(sys.argv[1], sys.argv[2])
)

# Get a generator of paginated results
response = client.pro_api.get_computer_inventory_v1(
	sections=["GENERAL", "SOFTWARE_UPDATES", "OPERATING_SYSTEM"],
	return_generator=True
)

# Prepare to write CSV
with open(filename, mode='w', newline='') as csvfile:
	fieldnames = [
		"Name", "JSS ID", "Asset Tag", "Current OS", "Last Check-in",
		"Update Name", "Package Name", "Update Version"
	]
	writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
	writer.writeheader()
	
	count = 0
	for page in response:
		for computer in page.results:
			name = computer.general.name if computer.general else "Unknown"
			asset_tag = computer.general.assetTag if computer.general else "None"
			last_checkin = computer.general.lastContactTime if computer.general else "Unknown"
			os_version = computer.operatingSystem.version if computer.operatingSystem else "Unknown"
			
			if computer.softwareUpdates:
				for update in computer.softwareUpdates:
					if (
						"macOS Sequoia" in update.name
						and os_version not in ["15.7", "15.7.1", "15.7.0"]
					):
						writer.writerow({
							"Name": name,
							"JSS ID": computer.id,
							"Asset Tag": asset_tag,
							"Current OS": os_version,
							"Last Check-in": last_checkin,
							"Update Name": update.name,
							"Package Name": update.packageName,
							"Update Version": update.version
						})
						count += 1
					
print(f"Total matching records: {count}")
print(f"Data written to: {filename}")
