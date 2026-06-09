import sys
import csv
from datetime import datetime
from collections import Counter
from jamf_pro_sdk import JamfProClient
from jamf_pro_sdk import ApiClientCredentialsProvider
import getpass

# Retrieve command line arguments
jamf_url = sys.argv[1] 
clientID = sys.argv[2]
clientSecret = sys.argv[3]

# Get current user to save to desktop
currentUser = getpass.getuser()

# Initialize Jamf Pro client
client = JamfProClient(jamf_url, ApiClientCredentialsProvider(clientID, clientSecret))

response = client.pro_api.get_computer_inventory_v1(sections=["APPLICATIONS"])

# List of macOS built-in apps to exclude
excluded_apps = {
    "Console.app", "Calculator.app", "FaceTime.app", "Disk Utility.app", "TextEdit.app", "Chess.app",
    "Digital Color Meter.app", "Siri.app", "Screenshot.app", "Grapher.app", "Activity Monitor.app",
    "Home.app", "VoiceOver Utility.app", "Stocks.app", "AirPort Utility.app", "Contacts.app",
    "System Information.app", "FindMy.app", "Audio MIDI Setup.app", "Boot Camp Assistant.app",
    "Shortcuts.app", "App Store.app", "Migration Assistant.app", "Automator.app", "Reminders.app",
    "Time Machine.app", "Calendar.app", "QuickTime Player.app", "TV.app", "Safari.app", "Maps.app",
    "Books.app", "Photo Booth.app", "Photos.app", "Font Book.app", "Launchpad.app", "Podcasts.app",
    "ColorSync Utility.app", "News.app", "VoiceMemos.app", "Script Editor.app", "Dictionary.app",
    "Stickies.app", "Music.app", "Messages.app", "Image Capture.app", "Bluetooth File Exchange.app",
    "Notes.app", "Preview.app", "Mission Control.app", "Terminal.app", "Mail.app", "Freeform.app",
    "Clock.app", "System Settings.app", "Weather.app","Screen Sharing.app", "Print Center.app", "Passwords.app","Tips.app","iPhone Mirroring.app", "Image Playground.app","Keynote.app","iMovie.app","Pages.app","GarageBand.app", "Numbers.app"
}

# Retrieve computer inventory data
response = client.pro_api.get_computer_inventory_v1(sections=["APPLICATIONS"])

app_counter = Counter()

# Loop through each computer
for computer in response:
    applications = getattr(computer, "applications", [])
    for app in applications:
        app_name = getattr(app, "name", "Unknown")
        if app_name in excluded_apps:
            continue
        app_counter[app_name] += 1

# Create filename with timestamp
timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
filename = f"/Users/{currentUser}/Desktop/appList_macOS_{timestamp}.csv"

# Write results to CSV
with open(filename, mode="w", newline="", encoding="utf-8") as csv_file:
    writer = csv.writer(csv_file)
    writer.writerow(["Application Name", "Count"])
    for app_name, count in app_counter.items():
        writer.writerow([app_name, count])

print(f"App list saved to {filename}")