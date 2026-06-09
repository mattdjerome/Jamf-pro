#!/usr/bin/env python3

from local_credentials import jamf_user, jamf_password, jamf_hostname
from jamf_pro_sdk import JamfProClient, BasicAuthProvider
from jamf_pro_sdk.clients.pro_api.pagination import SortField
import json

client = JamfProClient(jamf_hostname, BasicAuthProvider(jamf_user, jamf_password))


response = client.pro_api.get_computer_inventory_v1(sections=["GENERAL","EXTENSION_ATTRIBUTES"],sort_expression=SortField("id").asc(),)
#	page_size=1000)
##print(response)
#for computers in response:
#	print(computers.general.name)
##print(noSiteCount)
    
from jamf_pro_sdk import JamfProAPI
    
# Initialize the Jamf Pro API client
api = JamfProAPI(
    base_url='https://your-jamf-pro-instance-url',
    username='your-username',
    password='your-password'
)
    
# Fetch the list of all computer extension attributes
response = api.computer_extension_attributes.get_all()
    
# Print out the definitionId and name for each extension attribute
for attribute in response:
    definition_id = attribute.definitionId
    name = attribute.name
    print(f"Definition ID: {definition_id}, Name: {name}")
    
    # If you are looking for a specific definitionId (e.g., 79)
    if definition_id == 79:
        print(f"Found the attribute with definitionId 79: {name}")
        break