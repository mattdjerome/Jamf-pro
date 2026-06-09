#!/usr/bin/env python3

import requests
import sys
import json
import csv
from datetime import datetime
import getpass

# Get Current User and Current Date for output file name
username = getpass.getuser()
date = datetime.today().strftime('%Y%m%d-%H%M%S')

# Getting the base URL, client ID, client secret, and output CSV file path as arguments
baseURL = sys.argv[1]
url = f"{baseURL}/api/v1/oauth/token"
clientID = sys.argv[2]
clientSecret = sys.argv[3]
output_csv = f"/Users/{username}/Desktop/users_with_multiple_computers_{date}.csv"  # New argument for the CSV file path

# OAuth token request
payload = {
    "grant_type": "client_credentials",
    "client_id": f"{clientID}",
    "client_secret": f"{clientSecret}"
}
headers = {
    "accept": "application/json",
    "content-type": "application/x-www-form-urlencoded"
}

response = requests.post(url, data=payload, headers=headers)
result = response.json()
token = result['access_token']

def jamf_data(jamf_url, api_token):
    # Define headers for API request with Bearer token
    headers = {
        'accept': 'application/json',
        'Authorization': f'Bearer {api_token}',
    }

    # API request to get computer data
    params = {
        'section': [
            'GENERAL',
            'USER_AND_LOCATION',
            'HARDWARE',
            'APPLICATIONS'
        ],
        'page': '0',
        'page-size': '2000',
        'sort': 'id:asc',
    }
    response = requests.get(jamf_url + '/api/preview/computers', params=params, headers=headers)
    results = response.json()
    return results['results']

# Get the list of computers and process them
computers = jamf_data(baseURL, token)
users = {}
execs = ["alowahkee", "camscott"]
for user in computers:
    username = user['location']['username']
    if username in execs:  # if the username is in execs, skip to the next user
        continue
    # Ensure the user has a list for storing computer names
    if username not in users:
        users[username] = []

    # Append the computer name to the user's list
    users[username].append(user['name'])

# Check if any user has more than one computer
multi_computer_users = {user: computers for user, computers in users.items() if len(computers) > 1}

# Output the number of unique users and the list of users with more than 1 computer
print(f"Number of users with more than one computer: {len(multi_computer_users)}")
print(json.dumps(multi_computer_users, indent=4))  # Nicely formatted JSON output

# Write the data to a CSV file
with open(output_csv, mode='w', newline='') as file:
    writer = csv.writer(file)
    
    # Write header: 'Username', 'Email', computer columns, status columns, and notes column
    max_computers = max(len(computers) for computers in multi_computer_users.values())  # Find the max number of computers any user has
    header = ['Username', 'Email']  # Include 'Email' column header
    
    # Add columns for each computer and corresponding status
    for i in range(max_computers):
        header.append(f'Computer {i+1}')
        header.append(f'Status {i+1}')
    
    # Add 'Notes' column at the end
    header.append('Notes')

    writer.writerow(header)  # Write header row
    
    # Write data rows
    for username, computers in multi_computer_users.items():
        email = f"{username}@fanatics.com"  # Create email by appending @fanatics.com to username
        row = [username, email]  # Include email in the row
        # Add computer names and empty status columns
        for i in range(max_computers):
            if i < len(computers):
                row.append(computers[i])  # Add computer name
                row.append('')  # Empty status column
            else:
                row.append('')  # If user has fewer computers, fill with empty cells
                row.append('')
        
        # Add 'Notes' column at the end
        row.append('')  # Empty notes column
        
        writer.writerow(row)  # Write the user row

print(f"CSV output has been written to {output_csv}")
