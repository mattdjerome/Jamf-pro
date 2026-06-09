import requests
from requests.auth import HTTPBasicAuth
import xml.etree.ElementTree as ET
import sys

# Configuration from command-line arguments
if len(sys.argv) != 5:
    print("Usage: python script.py <jamf_url> <api_user> <api_password> <exclusion_group_id>")
    sys.exit(1)

jamf_url = sys.argv[1]
api_user = sys.argv[2]
api_password = sys.argv[3]
exclusion_group_id = sys.argv[4]  # keep as string for XML comparison

headers = {
    'Accept': 'application/xml',
    'Content-Type': 'application/xml'
}

def get_configuration_profiles():
    url = f'{jamf_url}/JSSResource/osxconfigurationprofiles'
    response = requests.get(url, auth=HTTPBasicAuth(api_user, api_password), headers=headers)
    response.raise_for_status()
    return response.content

def update_profile_scope(profile_id, exclusions_xml):
    url = f'{jamf_url}/JSSResource/osxconfigurationprofiles/id/{profile_id}/scope'
    response = requests.put(url, auth=HTTPBasicAuth(api_user, api_password), headers=headers, data=exclusions_xml)
    response.raise_for_status()
    print(f'Updated scope for profile {profile_id}')

def add_exclusion_to_profiles():
    profiles_xml = get_configuration_profiles()
    root = ET.fromstring(profiles_xml)
    for profile in root.findall('configuration_profile'):
        profile_id = profile.find('id').text
        profile_name = profile.find('name').text
        print(f'Processing profile: {profile_name} (ID: {profile_id})')

        # Get current scope
        scope_url = f'{jamf_url}/JSSResource/osxconfigurationprofiles/id/{profile_id}/scope'
        scope_response = requests.get(scope_url, auth=HTTPBasicAuth(api_user, api_password), headers=headers)
        scope_response.raise_for_status()
        scope_root = ET.fromstring(scope_response.content)

        # Locate or create exclusions element
        exclusions = scope_root.find('exclusions')
        if exclusions is None:
            exclusions = ET.SubElement(scope_root, 'exclusions')

        # Check if exclusion group already present
        group_exists = any(group.find('id').text == exclusion_group_id for group in exclusions.findall('computer_group'))
        if not group_exists:
            new_exclusion = ET.SubElement(exclusions, 'computer_group')
            ET.SubElement(new_exclusion, 'id').text = exclusion_group_id
            ET.SubElement(new_exclusion, 'name').text = 'Exclusion Group'  # Optional, can be omitted or customized

            # Convert back to XML string
            exclusions_xml = ET.tostring(scope_root, encoding='utf-8')

            # Update scope with new exclusion
            update_profile_scope(profile_id, exclusions_xml)
        else:
            print(f'Exclusion group {exclusion_group_id} already present in profile {profile_name} (ID: {profile_id})')

if __name__ == '__main__':
    try:
        add_exclusion_to_profiles()
    except requests.exceptions.RequestException as e:
        print(f'HTTP error occurred: {e}')
    except Exception as e:
        print(f'An error occurred: {e}')
