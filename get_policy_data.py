#!/usr/bin/env python3

import requests
import base64
import json
import sys

# Configuration
jamf_url = sys.argv[1]  # Replace with your Jamf instance
client_id = sys.argv[2]               # Replace with your Client ID
client_secret = sys.argv[3]         # Replace with your Client Secret
print(jamf_url,client_id, client_secret)
# Step 1: Get Bearer Token using client credentials
def get_bearer_token(jamf_url, client_id, client_secret):
	token_url = f"{jamf_url}/api/v1/auth/token"
	
	# Base64 encode the client credentials
	credentials = f"{client_id}:{client_secret}"
	encoded_credentials = base64.b64encode(credentials.encode()).decode()
	
	headers = {
		"Authorization": f"Basic {encoded_credentials}",
		"Content-Type": "application/x-www-form-urlencoded",
		"Accept": "application/json"
	}
	
	response = requests.post(token_url, headers=headers)
	
	if response.status_code == 200:
		token = response.json().get("token")
		return token
	else:
		raise Exception(f"Failed to get token: {response.status_code} {response.text}")
		
# Step 2: Use Bearer Token to access Classic API
def get_policies(jamf_url, bearer_token):
	print(bearer_token)
	api_url = f"{jamf_url}/JSSResource/policies"
	
	headers = {
		"Authorization": f"Bearer {bearer_token}",
		"Accept": "application/json"
	}
	
	response = requests.get(api_url, headers=headers)
	
	if response.status_code == 200:
		# Pretty print JSON response using json library
		data = response.json()
		print(json.dumps(data, indent=2))
	else:
		raise Exception(f"Failed to get policies: {response.status_code} {response.text}")
		
# Run the flow
try:
	token = get_bearer_token(jamf_url, client_id, client_secret)
	get_policies(jamf_url, token)
except Exception as e:
	print(f"Error: {e}")
	