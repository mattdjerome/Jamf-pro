#!/usr/bin/env python3

from local_credentials import jamf_user, jamf_password, jamf_hostname
import requests
import json
from datetime import datetime
import csv
import sys
import getpass

def get_username():
	return getpass.getuser()
user = get_username()

def get_uapi_token(jamf_hostname,jamf_user, jamf_password):
	
	jamf_test_url = 'https://' + jamf_hostname + "/api/v1/auth/token"
	headers = {'Accept': 'application/json', }
	response = requests.post(url=jamf_test_url, headers=headers, auth=(jamf_user, jamf_password))
	response_json = response.json()
	
	return response_json['token']

def get_computers(jamf_hostname, bearer_token):
	full_url = 'https://' + jamf_hostname + '/api/v1/computers-inventory'
	headers = {
		'accept': 'application/json',
		'Authorization': f'Bearer {bearer_token}',
	}
	
	params = {
		'section': [
			'GENERAL',
			'APPLICATIONS',
			'USER_AND_LOCATION',
			'EXTENSION_ATTRIBUTES',
			'SECURITY',
			'HARDWARE'
		],
		'page': '0',
		'page-size': '1600',
		'sort': 'general.name:asc',
	}
	
	response = requests.get(full_url, params=params, headers=headers)
	results = response.json()
	return results['results']
####### Current User #########
user = get_username()

####### Get Auth Token #########
token = get_uapi_token(jamf_hostname,jamf_user, jamf_password)

####### Put all Computers int oa Local Variable #######
all_computers = get_computers(jamf_hostname,token)

####### Read CSV of PCI Users #######
fullName = []
user = getpass.getuser()
path = f'/Users/{user}/Downloads/fullnames.csv'
with open(f'{path}') as file_obj:
	reader_obj = csv.reader(file_obj)
	for row in reader_obj:
		fullName.append((row[0]))

####### Gather the PCI data #######
# Get the current date
current_date = datetime.now()

# Format the date as year-month-day
date = current_date.strftime('%Y-%m-%d')

# Print the formatted date
apps_to_check = ['Falcon.app', 'QualysCloudAgent.app']
with open(f'PCI_Report_{date}.csv', mode='wt', encoding='utf-8') as report_output:
	writer = csv.writer(report_output)
	writer.writerow(('Full Name', 'email', 'Computer Name', 'Serial Number','Model', 'Firewall Enabled', 'Crowdstrike Installed', 'Qualys Installed'))
	
	for user in all_computers:
		for name in fullName:
			falconExist = 'False'
			qualysExist = 'False'
			if name == user['userAndLocation']['realname']:
				full_name = user['userAndLocation']['realname']
				email = user['userAndLocation']['email']
				computer = user['general']['name']
				serialNumber = user['hardware']['serialNumber']
				model = user['hardware']['model']
				firewallStatus = user['security']['firewallEnabled']
				installed_apps = [app['name'] for app in user.get('applications', [])]
				for app in apps_to_check:
					if app in installed_apps:
						if app == 'Falcon.app':
							falconExist = 'True'
						elif app == 'QualysCloudAgent.app':
							qualysExist = 'True'
				writer.writerow((full_name, email, computer, serialNumber, model, firewallStatus,falconExist,qualysExist))
