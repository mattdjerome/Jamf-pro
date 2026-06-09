#!/usr/bin/env python3

from local_credentials import jamf_user, jamf_password, jamf_hostname
from jamf_pro_sdk import JamfProClient, BasicAuthProvider
from jamf_pro_sdk.clients.pro_api.pagination import SortField
import json
import datetime
client = JamfProClient(jamf_hostname, BasicAuthProvider(jamf_user, jamf_password))


response = client.pro_api.get_computer_inventory_v1(sections=["GENERAL","EXTENSION_ATTRIBUTES"],sort_expression=SortField("id").asc(),
	page_size=1000)
#print(response)
for computers in response:
	for ea in computers.general.extensionAttributes:
#		if ea.name is "Privilege Elevation Reasons":
		print(computers.id,computers.general.name, ea.name,ea.values)
		