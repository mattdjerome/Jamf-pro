#!/usr/bin/env python3
import time
import os
import subprocess
import json
import webbrowser
import shutil
import logging
#######################################
# Pre-Flight Checks
#######################################
####################################### Create Logging #######################################
def setup_logging(log_file_path: str) -> logging.Logger:
	fmt = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')
	
	root = logging.getLogger()
	root.setLevel(logging.INFO)
	
	console_handler = logging.StreamHandler()
	console_handler.setFormatter(fmt)
	
	file_handler = logging.FileHandler(log_file_path)
	file_handler.setFormatter(fmt)
	
	root.addHandler(console_handler)
	root.addHandler(file_handler)
	
	return logging.getLogger(__name__)

log_location='/private/var/log/jamf_dr.log'
logger = setup_logging(log_location)

#logger.debug("This won't print because level is set to INFO")
#logger.info("This is an informational message")
#logger.warning("This is a warning!")

####################################### Check for binaries function #######################################
JAMF_HELPER = "/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper"
def prompt_missing_binary(binary_name: str, icon_path: str,url: str) -> bool:
	"""
	Prompt the user that a required binary is missing.
	Returns True if they clicked 'Open Installer', False if they clicked 'Exit'.
	"""
	result = subprocess.run(
		[
			JAMF_HELPER,
			"-windowType", "utility",
			"-title", f"{binary_name} Missing",
			"-heading", f"The {binary_name} Binary Was Not Found",
			"-description", f'The {binary_name} binary was not found on this Mac. Select "Open Installer" to open the developers setup guide.',
			"-icon", icon_path,
			"-button1", "Open Installer",
			"-button2", "Exit",
			"-defaultButton", "1",
			"-cancelButton", "2",
		],
		capture_output=True,
	)
	if result.returncode == 2:
		logging.warning("User selected exit")
	else:
		logging.info("User selected to open installer page")
		logging.info(f"Opening {binary_name} installer page in default web browser")
		webbrowser.open(url, new=0, autoraise=True)
	return result.returncode == 0

def binary_check(name, url):
	binary_path = shutil.which(name)
	logging.info(f"Checking for the {name} binary")
	if binary_path:
		print(f"Success! The {name} binary exists at: {binary_path}")
		logging.info(f"Success! The {name} binary exists at: {binary_path}")
	else:
		print(f"Error: {name} is not installed or not in PATH.")
		logging.warning(f"Error: {name} is not installed or not in PATH. Notifying user to install {name}")
		prompt_missing_binary(f"{name}", '/Library/Fanatics/Fanatics_icon.png',f"{url}")

		
		
####################################### Checking for binaries #######################################
binary_check("jamf-cli", "https://github.com/Jamf-Concepts/jamf-cli/wiki/Setup-Guide#setup-guide")
binary_check("dialog", "https://github.com/swiftDialog/swiftDialog/wiki")

####################################### List of Items Available for Backup/Restore #######################################
backupItems = ["All ","policies", "profiles", "scripts", "extension-attributes", "smart-groups", "static-groups", "categories", "buildings","departments","mac-apps","mobile-apps","packages","inventory-preloads","blueprints","compliance-benchmarks"]

####################################### Folder Selector Function #######################################
def select_folder_via_applescript():
	logging.info("Opening the folder picker")
	# AppleScript command to open a native folder picker
	cmd = "osascript -e 'POSIX path of (choose folder with prompt \"Choose a Folder\")'"
	logging.info("Folder Picker Open")
	try:
		# Run the command and capture the output path
		output = subprocess.check_output(cmd, shell=True, text=True).strip()
		logging.info(f"Folder location {output} selected.")
		return output
	except subprocess.CalledProcessError:
		logging.warning("User clicked cancel button.")
		return None  # User clicked Cancel

####################################### Gather Jamf CLI Configuration Data #######################################
cliProfiles = subprocess.run(["jamf-cli","config","list","-o","json"],capture_output=True, text=True)
cliProfiles = json.loads(cliProfiles.stdout)
profileNames = []
for names in cliProfiles:
	profileNames.append(names['name'])

####################################### Make the UI #######################################
dialogTitle           = "DR Jamf"
dialogSubtitle        = "Welcome to DR Jamf"
dialogMessage         = "test message"
dialogStyle           = "mini"
dialogMessagePosition = "center"
dialogIcon            = ""
selectTitle           = "Backup Or Restore"
selectValues          = "Backup, Restore"

cmd = ["dialog"]

if dialogTitle:
	cmd += ["--title",            dialogTitle]
if dialogSubtitle:
	cmd += ["--subtitle",         dialogSubtitle]
if dialogMessage:
	cmd += ["--message",          dialogMessage]
#if dialogStyle:
#	cmd += ["--style",            dialogStyle]
if dialogMessagePosition:
	cmd += ["--messageAlignment", dialogMessagePosition]
if dialogIcon:
	cmd += ["--icon",             dialogIcon]
if selectTitle:
	cmd += ["--selecttitle",      f"{selectTitle},required"]
if selectValues:
	cmd += ["--selectvalues",     selectValues]
logging.info("Launching swiftDialog UI")
result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)

if result.returncode == 0:
	logging.info(f"User selected: {result.stdout.strip()}")
	# Create a window for Backing up
elif result.returncode == 1:
	logging.info(f"User selected: {result.stdout.strip()}")
elif result.returncode == 2:
	logging.warning("User cancelled the dialog")
else:
	logging.warning(f"Dialog exited with unexpected return code: {result.returncode}")