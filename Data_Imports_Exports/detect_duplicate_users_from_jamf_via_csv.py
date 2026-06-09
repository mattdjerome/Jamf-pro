#!/usr/bin/env python3
import sys
import csv
from csv import DictReader
from collections import Counter

jamfDataFile = sys.argv[1]
users = {}

with open(jamfDataFile, 'r', encoding='unicode_escape') as jamfData:
    for line in csv.DictReader(jamfData):
        users[line['Computer Name']] = line['Email Address']

# Count the occurrences of each email address
email_counts = Counter(users.values())

# Find email addresses that are associated with multiple computer names
duplicate_emails = {email: count for email, count in email_counts.items() if count > 1}

print("Email addresses associated with multiple computer names:")
for email, count in duplicate_emails.items():
    print(f"{email},{count}")