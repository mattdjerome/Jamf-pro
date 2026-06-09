#!/bin/bash

services=()
i=0

# Use command substitution and a classic while loop
networksetup -listallnetworkservices > /tmp/net_services.txt

while IFS= read -r line; do
    # Skip the first line (header)
    if [ $i -gt 0 ]; then
        services+=("$line")
    fi
    i=$((i + 1))
done < /tmp/net_services.txt

# Print the services to verify
for service in "${services[@]}"; do
    echo "$service"
done

for service in "${services[@]}"; do
    echo "Setting to Link Local for: $service"
    networksetup -setv6linklocal "$service"
done
