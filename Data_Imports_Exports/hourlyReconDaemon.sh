#!/bin/bash

LAUNCH_DAEMON_BASE_64="PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4KPCFET0NUWVBFIHBsaXN0IFBVQkxJQyAiLS8vQXBwbGUvL0RURCBQTElTVCAxLjAvL0VOIiAiaHR0cDovL3d3dy5hcHBsZS5jb20vRFREcy9Qcm9wZXJ0eUxpc3QtMS4wLmR0ZCI+CjxwbGlzdCB2ZXJzaW9uPSIxLjAiPgo8ZGljdD4KCTxrZXk+R3JvdXBOYW1lPC9rZXk+Cgk8c3RyaW5nPndoZWVsPC9zdHJpbmc+Cgk8a2V5PkxhYmVsPC9rZXk+Cgk8c3RyaW5nPmNvbS5yZWNvbi5ob3VybHk8L3N0cmluZz4KCTxrZXk+UHJvZ3JhbUFyZ3VtZW50czwva2V5PgoJPGFycmF5PgoJCTxzdHJpbmc+L3Vzci9sb2NhbC9qYW1mL2Jpbi9qYW1mPC9zdHJpbmc+CgkJPHN0cmluZz5yZWNvbjwvc3RyaW5nPgoJPC9hcnJheT4KCTxrZXk+UnVuQXRMb2FkPC9rZXk+Cgk8dHJ1ZS8+Cgk8a2V5PlN0YXJ0SW50ZXJ2YWw8L2tleT4KCTxpbnRlZ2VyPjM2MDA8L2ludGVnZXI+Cgk8a2V5PlVzZXJOYW1lPC9rZXk+Cgk8c3RyaW5nPnJvb3Q8L3N0cmluZz4KPC9kaWN0Pgo8L3BsaXN0Pgo=
"
# The base 64 translates to this Launch Daemon plist. It instructs the jamf binary to run an inventory once an hour
#<?xml version="1.0" encoding="UTF-8"?>
#<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
#<plist version="1.0">
#<dict>
#<key>GroupName</key>
#<string>wheel</string>
#<key>Label</key>
#<string>com.recon.hourly</string>
#<key>ProgramArguments</key>
#<array>
#<string>/usr/local/jamf/bin/jamf</string>
#<string>recon</string>
#</array>
#<key>RunAtLoad</key>
#<true/>
#<key>StartInterval</key>
#<integer>3600</integer>
#<key>UserName</key>
#<string>root</string>
#</dict>
#</plist>

PLIST_LOCATION="/Library/LaunchDaemons/com.recon.hourly.plist"


echo "$LAUNCH_DAEMON_BASE_64" | base64 -D -o $PLIST_LOCATION

chown root:wheel $PLIST_LOCATION

chmod 600 $PLIST_LOCATION

/bin/launchctl load /Library/LaunchDaemons/com.recon.hourly.plist

