#!/usr/bin/env python3

import sys
import csv
from jamf_pro_sdk import JamfProClient, ApiClientCredentialsProvider
import csv
import argparse
import getpass

# -----------------------
# Required Attributes
# -----------------------
parser = argparse.ArgumentParser()
parser.add_argument("-j","--jamfProURL", type=str, help="Your Jamf Pro URL")
parser.add_argument("-cid","--clientId", type=str, help="Jamf Pro Client ID")
parser.add_argument("-cs","--clientSecret", type=str, help="Jamf Pro Client Secret")

args = parser.parse_args()

### Retrieve Jamf Computer Data

client = JamfProClient(args.jamfProURL, ApiClientCredentialsProvider(args.clientId, args.clientSecret))
computers = client.pro_api.get_computer_inventory_v1(sections=["GENERAL","HARDWARE","USER_AND_LOCATION"])

# Requires import sys
def read_csv(file_path):
	corpUsers = []
	with open(file_path, newline='') as csvfile:
		reader = csv.reader(csvfile)
		for row in reader:
			corpUsers.append(row[0])
	return corpUsers

fhiUsers = read_csv('/Users/mjerome/Library/CloudStorage/OneDrive-Fanatics,Inc/corpUsers.csv')
jamf_Users = []
for realname in computers:
	jamf_Users.append(realname.userAndLocation.realname)
print("")
for corpUsers in fhiUsers:
	if corpUsers not in jamf_Users:
		continue
	else:
		print(corpUsers)