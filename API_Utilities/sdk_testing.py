#!/usr/bin/python3

from jamf_pro_sdk import JamfProClient, BasicAuthProvider
from jamf_pro_sdk.clients.pro_api.pagination import SortField
import json
from getpass import getpass
from jamf_pro_sdk import ApiClientCredentialsProvider

client = JamfProClient(
	server=jamf_hostname,
	credentials=ApiClientCredentialsProvider(client_id, client_secret)
)


response = client.pro_api.get_computer_inventory_v1()
for computers in response:
	try:
		print(computers.general.name,computers.userAndLocation.realname)
	except:
		print(computers)