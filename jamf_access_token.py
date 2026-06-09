#!/usr/bin/env python3

import time
import requests
import json
import sys

# Variables
url = sys.argv[1]
client_id = sys.argv[2]
client_secret = sys.argv[3]

# Global Variables
access_token = ""
token_expiration_epoch = 0

# Function to get a new access token
def get_access_token():
	global access_token, token_expiration_epoch
	response = requests.post(f"{url}/api/oauth/token", data={
		"client_id": client_id,
		"client_secret": client_secret,
		"grant_type": "client_credentials"
	}, headers={"Content-Type": "application/x-www-form-urlencoded"})
	
	if response.status_code == 200:
		response_data = response.json()
		access_token = response_data.get("access_token")
		expires_in = response_data.get("expires_in")
		current_epoch = int(time.time())
		token_expiration_epoch = current_epoch + expires_in - 1
	else:
		print(f"Error getting token: {response.status_code} - {response.text}")
	return access_token	
# Function to check if the token is expired or still valid
def check_token_expiration():
	global access_token, token_expiration_epoch
	current_epoch = int(time.time())
	
	if token_expiration_epoch >= current_epoch:
		print(f"Token valid until epoch time: {token_expiration_epoch}")
	else:
		print("No valid token available, getting new token")
		get_access_token()
		
# Function to invalidate the token
def invalidate_token():
	global access_token, token_expiration_epoch
	response = requests.post(
		f"{url}/api/v1/auth/invalidate-token", 
		headers={"Authorization": f"Bearer {access_token}"}
	)
	
	if response.status_code == 204:
		print("Token successfully invalidated")
		access_token = ""
		token_expiration_epoch = 0
	elif response.status_code == 401:
		print("Token already invalid")
	else:
		print(f"An unknown error occurred invalidating the token: {response.status_code} - {response.text}")
		
# Main execution
check_token_expiration()
if access_token:
	response = requests.get(
		f"{url}/api/v1/jamf-pro-version", 
		headers={"Authorization": f"Bearer {access_token}"}
	)
	print(response.json())
	
check_token_expiration()

if access_token:
	response = requests.get(
		f"{url}/api/v1/jamf-pro-version", 
		headers={"Authorization": f"Bearer {access_token}"}
	)
	print(response.json())
	
	
	


invalidate_token()