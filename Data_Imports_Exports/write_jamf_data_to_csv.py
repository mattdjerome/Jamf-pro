#!/usr/bin/env python3
from jamf_pro_sdk import JamfProClient, ApiClientCredentialsProvider
import csv
import argparse
from datetime import datetime
import getpass
# -----------------------
# Required Attributes
# -----------------------
parser = argparse.ArgumentParser()
parser.add_argument("-j","--jamfProURL", type=str, help="Your Jamf Pro URL")
parser.add_argument("-cid","--clientId", type=str, help="Jamf Pro Client ID")
parser.add_argument("-cs","--clientSecret", type=str, help="Jamf Pro Client Secret")
parser.add_argument("-ds","--daysSince", type=str, help="Days Since Last Checkin")
args = parser.parse_args()

### Retrieve Jamf Computer Data

client = JamfProClient(args.jamfProURL, ApiClientCredentialsProvider(args.clientId, args.clientSecret))
computers = client.pro_api.get_computer_inventory_v1(sections=["GENERAL","HARDWARE","USER_AND_LOCATION"])

### Write data to CSV
timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
currentUser = getpass.getuser()
filename = f"/Users/{currentUser}/Desktop/jamf_data_{timestamp}.csv"
noCheckIn = []
with open(filename, mode="x", newline="", encoding="utf-8") as csv_file:
		writer = csv.writer(csv_file)
		writer.writerow(["JSS ID", "Hostname", "Serial Number","Assigned User","Days Since Last Checkin"]) #row header
		# Starts to cycle through all the data and write to the desired output
		for macs in computers: #cycle through data and add it to a csv
			if macs.general.lastContactTime !=None:
				lastContact = macs.general.lastContactTime
				lastCheckin = datetime.fromisoformat(f"{lastContact}")
				year = lastCheckin.year
				month = lastCheckin.month
				day = lastCheckin.day
				today = datetime.today()
				lastCheckinDate = datetime(year, month, day)
				date_difference = today - lastCheckinDate
				print(date_difference)
				if int(date_difference.days) > int(args.daysSince):
					noCheckIn.append(macs.general.name)
					writer = csv.writer(csv_file)
					print(macs.id ,macs.general.name,macs.hardware.serialNumber, macs.userAndLocation.username, date_difference.days)
					writer.writerow([macs.id ,macs.general.name,macs.hardware.serialNumber, macs.userAndLocation.username, date_difference.days])
			
		writer.writerow([f"{len(noCheckIn)} macs detected"])