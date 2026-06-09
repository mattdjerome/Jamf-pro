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

args = parser.parse_args()

### Retrieve Jamf Computer Data

client = JamfProClient(args.jamfProURL, ApiClientCredentialsProvider(args.clientId, args.clientSecret))
computers = client.pro_api.get_computer_inventory_v1(sections=["GENERAL","HARDWARE","USER_AND_LOCATION"])
print("")