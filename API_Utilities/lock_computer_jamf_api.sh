#!/bin/bash
# Outline
# Check if Swift Dialog is present
# if not, install swift dialog
# Get serial number computer
# Generate token via ID and Secret
# verify token
# Verify that serial is in Jamf and return computer data
# Tech confirm its the correct computer
# Generate random 6 digit code
# Display Data
# Ask User to confirm all is correct
# Double Confirm all is correct
# MDM Lock computer via API
# Update Service Now status
# invalidate token



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Pre-flight Check: Client-side Script Logging Function
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

scriptLog="${4:-"/Library/Logs/remoteComputerLock.log"}"                        # Parameter 4: Script Log Location 

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Pre-flight Check: Variables
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
url=
client_id=
client_secret=

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Pre-flight Check: Client-side Script Logging Function
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

function updateScriptLog() {
	echo -e "$( date +%Y-%m-%d\ %H:%M:%S ) - ${1}" | tee -a "${scriptLog}"
}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Pre-flight Check: Validate / install swiftDialog (Thanks big bunches, @acodega!)
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

function dialogInstall() {
	
	# Get the URL of the latest PKG From the Dialog GitHub repo
	dialogURL=$(curl -L --silent --fail "https://api.github.com/repos/swiftDialog/swiftDialog/releases/latest" | awk -F '"' "/browser_download_url/ && /pkg\"/ { print \$4; exit }")
	
	# Expected Team ID of the downloaded PKG
	expectedDialogTeamID="PWA5E9TQ59"
	
	updateScriptLog "PRE-FLIGHT CHECK: Installing swiftDialog..."
	
	# Create temporary working directory
	workDirectory=$( /usr/bin/basename "$0" )
	tempDirectory=$( /usr/bin/mktemp -d "/private/tmp/$workDirectory.XXXXXX" )
	
	# Download the installer package
	/usr/bin/curl --location --silent "$dialogURL" -o "$tempDirectory/Dialog.pkg"
	
	# Verify the download
	teamID=$(/usr/sbin/spctl -a -vv -t install "$tempDirectory/Dialog.pkg" 2>&1 | awk '/origin=/ {print $NF }' | tr -d '()')
	
	# Install the package if Team ID validates
	if [[ "$expectedDialogTeamID" == "$teamID" ]]; then
		
		/usr/sbin/installer -pkg "$tempDirectory/Dialog.pkg" -target /
		sleep 2
		dialogVersion=$( /usr/local/bin/dialog --version )
		updateScriptLog "PRE-FLIGHT CHECK: swiftDialog version ${dialogVersion} installed; proceeding..."
		
	else
		
		# Display a so-called "simple" dialog if Team ID fails to validate
		osascript -e 'display dialog "Please advise your Support Representative of the following error:\r\r• Dialog Team ID verification failed\r\r" with title "Setup Your Mac: Error" buttons {"Close"} with icon caution'
		completionActionOption="Quit"
		exitCode="1"
		quitScript
		
	fi
	
	# Remove the temporary working directory when done
	/bin/rm -Rf "$tempDirectory"
	
}



function dialogCheck() {
	
	# Output Line Number in `verbose` Debug Mode
	if [[ "${debugMode}" == "verbose" ]]; then updateScriptLog "PRE-FLIGHT CHECK: # # # SETUP YOUR MAC VERBOSE DEBUG MODE: Line No. ${LINENO} # # #" ; fi
	
	# Check for Dialog and install if not found
	if [ ! -e "/Library/Application Support/Dialog/Dialog.app" ]; then
		
		updateScriptLog "PRE-FLIGHT CHECK: swiftDialog not found. Installing..."
		dialogInstall
		
	else
		
		dialogVersion=$(/usr/local/bin/dialog --version)
		if [[ "${dialogVersion}" < "${swiftDialogMinimumRequiredVersion}" ]]; then
			
			updateScriptLog "PRE-FLIGHT CHECK: swiftDialog version ${dialogVersion} found but swiftDialog ${swiftDialogMinimumRequiredVersion} or newer is required; updating..."
			dialogInstall
			
		else
			
			updateScriptLog "PRE-FLIGHT CHECK: swiftDialog version ${dialogVersion} found; proceeding..."
			
		fi
		
	fi
	
}



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Capture Serial Number
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

function captureJSSID {
	response=$(dialog --title "Remote Computer Lock" \
	--icon /Library/Fanatics/Fanatics_icon.png \
	--message "This computer will be locked. Please enter the serial number of the computer" \
	--textfield "Jamf Pro Computer ID", prompt="Enter the Jamf Pro Computer ID")
	updateScriptLog "Response entered is ${response}"
	# Extract just the number
	computer_id=$(echo "$response" | awk -F': ' '/Jamf Pro Computer ID/ {print $2}')
	updateScriptLog "JSS ID is ${computer_id}"
	
}


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Get Jamf API client ID and Secret
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

function jamfAuthentication {
	if [[ -z "$client_id" ]]
	then
		echo -n "Client ID: "
		read client_id
	fi
	
	if [[ -z "$client_secret" ]]
	then
		echo -n "Client Secret: "
		read -s client_secret
	fi
}


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Check Jamf access token
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

current_epoch=$(date +%s)
function getAccessToken() {
		response=$(curl --silent --location --request POST "${url}/api/oauth/token" \
		--header "Content-Type: application/x-www-form-urlencoded" \
		--data-urlencode "client_id=${client_id}" \
		--data-urlencode "grant_type=client_credentials" \
		--data-urlencode "client_secret=${client_secret}")
		access_token=$(echo "$response" | plutil -extract access_token raw -)
	token_expires_in=$(echo "$response" | plutil -extract expires_in raw -)
	token_expiration_epoch=$(($current_epoch + $token_expires_in - 1))
	}

function checkTokenExpiration() {
	current_epoch=$(date +%s)
	if [[ $token_expiration_epoch -ge $current_epoch ]]
	then
		echo "Token valid until the following epoch time: " "$token_expiration_epoch"
	else
		echo "No valid token available, getting new token"
		getAccessToken
	fi
}

function invalidateToken() {
	responseCode=$(curl -w "%{http_code}" -H "Authorization: Bearer ${access_token}" $url/api/v1/auth/invalidate-token -X POST -s -o /dev/null)
	if [[ ${responseCode} == 204 ]]
	then
		echo "Token successfully invalidated"
		access_token=""
		token_expiration_epoch="0"
	elif [[ ${responseCode} == 401 ]]
	then
		echo "Token already invalid"
	else
		echo "An unknown error occurred invalidating the token"
	fi
}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Check Jamf Pro Computer ID
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

function checkJSSID {
	result=$(curl -X "GET" "${url}/api/v1/computers-inventory/${computer_id}/?section=USER_AND_LOCATION'" \
	-H "accept: application/json" \
	-H "Authorization: Bearer ${access_token}")

}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Generate 6 digit Code
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

function lockCode {
	code=""
	for i in {1..6}; do
		code+=$(( RANDOM % 10 ))
	done
	echo "Lock Code is: $code"
	updateScriptLog "Lock code is ${code}"
}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Gather Data From JSON
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
function getUsername {
	username=$(curl --silent \
	--header "Authorization: Bearer ${access_token}" \
	--header "Accept: application/json" \
	--request GET "${url}/api/v1/computers-inventory-detail/${computer_id}" | \
	jq -r '.userAndLocation.username // "No Username Present"')
	
	echo "Username is: $username"
}

function getAssetTag {
	assetTag=$(curl --silent \
	--header "Authorization: Bearer ${access_token}" \
	--header "Accept: application/json" \
	--request GET "${url}/api/v1/computers-inventory-detail/${computer_id}" | \
	jq -r '.general.assetTag // "No Asset Tag Present"')
	
	echo "Asset Tag is: $assetTag"
}

function getSerialNumber {
	serialNumber=$(curl --silent \
	--header "Authorization: Bearer ${access_token}" \
	--header "Accept: application/json" \
	--request GET "${url}/api/v1/computers-inventory-detail/${computer_id}" | \
	jq -r '.hardware.serialNumber // "No Serial Number Present"')
	
	echo "Serial Number is: $serialNumber"
}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Install Homebrew and jq
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
function install_homebrew_and_jq() {
	# Check for Homebrew
	if ! command -v brew &>/dev/null; then
		echo "Homebrew not found. Installing Homebrew..."
		/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
		
		# After install, add brew to PATH for this session if needed
		if [[ -d /opt/homebrew/bin ]]; then
			export PATH="/opt/homebrew/bin:$PATH"
		elif [[ -d /usr/local/bin ]]; then
			export PATH="/usr/local/bin:$PATH"
		fi
	else
		echo "Homebrew is already installed."
	fi
	
	# Check for jq
	if ! command -v jq &>/dev/null; then
		echo "jq not found. Installing jq..."
		brew install jq
	else
		echo "jq is already installed."
	fi
}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Display in Swift Dialog
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
function displayInformation {
	dialog --title "Remote Computer Lock Data" --subtitle "Verify This Data is Correct Before Moving Forward"
	
}


install_homebrew_and_jq 
dialogCheck
captureJSSID
jamfAuthentication 
getAccessToken 
checkTokenExpiration 
checkJSSID
getUsername
getAssetTag
getSerialNumber
lockCode 
invalidateToken 