#!/usr/local/ec/bin/python3

# https://developer.code42.com/api/#tag/Device
# https://support.code42.com/Incydr/Admin/Configuring/Grant_Code42_permissions_to_macOS_devices#Sample_computer_configuration_profile

import csv
import datetime
import requests

from local_credentials import c42_clientid, c42_secret, c42_api_endpoint, c42_console_endpoint


def get_jwt_token():

    c42_test_url = f"{c42_api_endpoint}/v1/oauth"
    headers = {'Accept': 'application/json', }
    response = requests.post(url=c42_test_url, headers=headers, auth=(c42_clientid, c42_secret))
    response_json = response.json()

    return response_json['access_token']


def main():
    jwt_token = get_jwt_token()

    headers = {'cache-control': 'no-cache', 'Accept': 'application/json', 'authorization': 'Bearer ' + jwt_token}
    page = 1
    page_size = 500
    keep_going = True
    date = datetime.date.today()
    
    with open(f'Code42_FullDiskAccess_report_{date}.csv', mode='wt', encoding='utf-8') as report_output:
        writer = csv.writer(report_output)
        writer.writerow(('deviceId', 'Name', 'Status', 'FDA Active','Last Code42 Heartbeat'))

        while keep_going:
            device_list_response = requests.get(url=f'{c42_api_endpoint}/v1/devices?page={page}&pageSize={page_size}', headers=headers)
            device_list = device_list_response.json()['devices']

            for device in device_list:
                if device['active'] is False or device['status'] == 'Deactivated, Blocked'or device['status'] == 'Deactivated' or device['status'] == 'Deactivated, Blocked' or device['status'] == 'Active, Blocked, Deauthorized' or device['status'] == 'Active, Blocked' or device['status'] == 'Active, Deauthorized':
                    continue
                device_response = requests.get(url=f"{c42_console_endpoint}/api/v12/agent-state/view-by-device-guid?deviceGuid={device['deviceId']}&propertyName=fullDiskAccess", headers=headers)
                device_response_json = device_response.json()
                if isinstance(device_response_json, dict):
                    # print(f"{device['deviceId']:20} {device['name']:50} {device['status']:13} {device_response_json['data']['name']:16} {device_response_json['data']['value']}")
                    writer.writerow([device['deviceId'], device['name'], device['status'], device_response_json['data']['value'], device['lastConnected']])
                else:
                    # print(f"{device['deviceId']:20} {device['name']:50} {device['status']:13} unknown")
                    writer.writerow([device['deviceId'], device['name'], device['status'], 'unknown', device['lastConnected']])

            print(f"#{page:<3} devices:{len(device_list)} status code:{device_list_response.status_code} url:{device_list_response.url}")

            if len(device_list) != page_size:
                keep_going = False
            else:
                page += 1


if __name__ == '__main__':
    main()
    print("complete")