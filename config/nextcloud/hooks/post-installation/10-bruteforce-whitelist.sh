#!/bin/sh
# Populate bruteForce app whitelist from ALLOW_IP_RANGES env var.
# This runs once after a fresh Nextcloud installation.

if [ -z "$ALLOW_IP_RANGES" ]; then
  echo "ALLOW_IP_RANGES not set, skipping brute force whitelist setup"
  exit 0
fi

# Remove existing entries
for key in $(php /var/www/html/occ config:list bruteForce 2>/dev/null | grep -o '"whitelist_[0-9]*"' | tr -d '"'); do
  php /var/www/html/occ config:app:delete bruteForce "$key"
done

# Add each range from ALLOW_IP_RANGES (comma or space separated)
i=1
echo "$ALLOW_IP_RANGES" | tr ',' '\n' | tr ' ' '\n' | while read -r range; do
  range=$(echo "$range" | tr -d '[:space:]')
  [ -z "$range" ] && continue
  php /var/www/html/occ config:app:set bruteForce "whitelist_$i" --value="$range"
  i=$((i + 1))
done
