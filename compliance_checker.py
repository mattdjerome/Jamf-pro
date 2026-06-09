#!/usr/bin/env python3


#################################################################
# Checks various items via the JAMF API to check compliance requirements
# It's designed to be run from a cloud system such as AWS or Azure
# In order to use, you'll need to change the JAMF URL's for your instance
# 
# It utilizes both the Classic and Pro API to retrieve various items
#
# Your Mileage may vary as items in API's do change
#
#
# Use at your own risk and I offer no warranty's or guarantees
#
# It did test successfully numerous times
#
# The final step in the process is to send and email to an address of your choice
# I've commented where data needs to be inputted.
#
# written by: Matt Jerome, September 2021

import subprocess
import smtplib
from datetime import datetime
from email.message import EmailMessage
import requests

JAMF_URL = '' # enter the JAMF url here
basic_auth = '' # enter the basic auth hash here

# Check JAMF for Encryption Status
def encryption_status(data):
	state = data['diskEncryption']['bootPartitionEncryptionDetails']['partitionFileVault2State']
	if state == "ENCRYPTED":
		return True
	else:
		return False
	
# Verify Recovery Key is Escrowed
def check_key(data):
	valid_key = data['diskEncryption']['individualRecoveryKeyValidityStatus']
	if valid_key == "VALID":
		return True
	else:
		return False
	
# Retrieve API Bearer token
def get_uapi_token(jamf_user, jamf_password, jamf_hostname):
	jamf_test_url = jamf_hostname + "/uapi/auth/tokens"
	header = {'Accept': 'application/json', }
	record = requests.post(url=jamf_test_url, headers=header, auth=(jamf_user, jamf_password))
	response_json = record.json()
	return response_json['token']


# Check OS Version
def os_version(data):
	version = data['operatingSystem']['version']
	return version


# Check installed applications
def installed_app(computer_name, app):
	url = f"{JAMF_URL}/JSSResource/computerapplications/application/{app}"
	headers = {
	"Accept": "application/xml",
	"Authorization": f"Basic {basic_auth}"
		}
	
	response = requests.request("GET", url, headers=headers)
	if computer_name in response.text:
		return True
	else:
		return False
	
# Checks last check in time
def check_in(data):
	last_date_full = data['general']['reportDate']
	last_year = int(last_date_full[0:4:1])
	last_month = int(last_date_full[5:7:1])
	last_day = int(last_date_full[8:10:1])
	right_now = datetime.now()
	f_date = datetime(last_year, last_month, last_day)
	delta = right_now - f_date
	return delta.days

# Get the person assigned to the computer
def name(data):
	try:
		fullname = data['userAndLocation']['realname']
	except:
		fullname = "Full Name Error"
	return fullname

# Gets user email address
def email_address(data):
	try:
		email = data['userAndLocation']['username']
	except:
		email = "User Email Error"
	return email

# File a zendesk ticket
def file_ticket(errors,computername, computerdata):
	user=''
	password = ''# Enter the credentials here
	smtpsrv = ""
	smtpserver = smtplib.SMTP(smtpsrv,587)
	msg = EmailMessage()
	msg['Subject'] = 'Compliance Alert'
	msg['From'] = ''
	msg['To'] = ''
	msg.set_content(f"The computer, {computername} is out of compliance because:\n\n{errors}\n{computerdata}")
	smtpserver.starttls()
	smtpserver.login(user, password)
	smtpserver.send_message (msg)
	smtpserver.close()
	
### This is where the stuff happens###
	
	
COMPUTERS_URL = f"{JAMF_URL}/JSSResource/computers"

headers = {
	"Accept": "application/json",
	"Authorization": f"Basic {basic_auth}"
}

response = requests.request("GET", COMPUTERS_URL, headers=headers)
results = response.json()

id_number=results['computers']
uapi_token = get_uapi_token('', '',
	f'{JAMF_URL}')

exclusions=[]

error=[]
requirement=[]
COUNT = 0
for i in id_number:
	hostname = i['name']
	# This checks if the computer is in the exclusiosn list, and if so goes to the next computer
	if hostname in exclusions:
		continue
	number = i['id']
	url = f"{JAMF_URL}/uapi/v1/computers-inventory-detail/{number}"
	jamf_url=f"{JAMF_URL}/computers.html?id={number}&o=r"
	headers = {
	"Accept": "application/json",
	"Authorization": f"Bearer {uapi_token}"
}
	
	response = requests.request("GET", url, headers=headers)
	results = response.json()
	
# Store the result of each function
	user_email = email_address(results)
	if user_email in exclusions:
		continue
	FV2_STATE = encryption_status(results)
	ESCROW = check_key(results)
	MACOS = os_version(results)
	apps_to_check = ['Code42.app','Falcon.app']
	missing_apps=[]
	if len(apps_to_check) > 0:
		for i in apps_to_check:
			result = installed_app(hostname, i)
		if result is False:
			missing_apps.append(f'{i}')
			error.append(f'{i} is not installed')
	if len(missing_apps) == 0:
		missing_apps.append("None")
	FULL_NAME = name(results)
	
	last_check_in = check_in(results)
	
	if FV2_STATE is False:
		error.append("Encryption Error")
	if ESCROW is False:
		error.append("Missing Recovery Key")
	if MACOS < "10.15.0":
		error.append("Unsupported version of macOS")
	if last_check_in > 14:
		error.append(f"{last_check_in} Days since last check in")
	if user_email == "None" or user_email == None:
		error.append("Unknown User Email")
	if FULL_NAME == "None" or user_email == None or FULL_NAME == "Full Name Error":
			error.append("Unknown Full Name")
	if len(error) > 0:
		computer_data=(f"\nJAMF URL - {jamf_url}\nHostname - {hostname}\nUser Email - {user_email}\nFull Name - {FULL_NAME}\nEncryption Status - {FV2_STATE}\nKey Escrow Status - {ESCROW}\nmacOS Version - {MACOS}\nMissing Apps - {missing_apps}\nDays Since Last Check-in - {last_check_in}\n")
		COUNT += 1
		print("\nComputer is not compliant")
		print(computer_data, error)
		error.clear()
print(f"Total computers out of compliance is {COUNT}")

