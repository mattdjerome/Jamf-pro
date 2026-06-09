#!/bin/bash

sleepStatus=$(pmset -g | awk '/SleepDisabled/ {print $2}')
if [[ $sleepStatus = 0 ]]; then
	echo "<result>False</result>"
elif [[ $sleepStatus = 1 ]]; then
	echo "<result>True</result>"
else
	echo "<result>Unknown</result>"
fi