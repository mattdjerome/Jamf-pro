#!/usr/bin/env python3

from jamf_pro_sdk import JamfPro
from jamf_pro_sdk.models.pro.computers import ComputerUserAndLocation
from jamf_pro_sdk.models.pro.computers.computer import Computer
from jamf_pro_sdk.api.pro.computers import ComputerApi
import requests

# Configuration
JAMF_PRO_URL = 'https://your-jamf-pro-url'
USERNAME = 'your-api-username'
PASSWORD = 'your-api-password'
COMPUTER_ID = 123  # Replace with the actual computer ID
NEW_USERNAME = 'newusername@example.com'

# Authenticate and create JamfPro client
jamf_pro_client = JamfPro(
	base_url=JAMF_PRO_URL,
	username=USERNAME,
	password=PASSWORD
)

# Fetch current computer data
computer_api = ComputerApi(jamf_pro_client)
computer = computer_api.get_computer_by_id(COMPUTER_ID)

if not computer:
	print("Computer not found")
	exit()
	
	# Update ComputerUserAndLocation.username
	computer_user_and_location = ComputerUserAndLocation(
		username=NEW_USERNAME
	)
	
	# Make the PUT request to update the computer's user and location
	update_response = jamf_pro_client.session.put(
		f"{JAMF_PRO_URL}/JSSResource/computers/id/{COMPUTER_ID}/subset/user-location",
		json=computer_user_and_location.dict()
	)
	
	if update_response.status_code == 200:
		print("Username updated successfully")
	else:
		print(f"Failed to update username: {update_response.status_code} - {update_response.text}")
		
