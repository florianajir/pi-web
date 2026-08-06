#!/bin/sh
# Mount the qBittorrent downloads folder as external storage so any
# downloaded file (not just photos, unlike Immich) can get a public
# Nextcloud share link. Restricted to the "admin" group.
# This runs once, right after a fresh Nextcloud installation.

MOUNT_NAME="Downloads"
MOUNT_PATH="/mnt/qbittorrent-downloads"
MOUNT_GROUP="admin"

if [ ! -d "$MOUNT_PATH" ]; then
  echo "$MOUNT_PATH not mounted into this container, skipping external storage setup"
  exit 0
fi

php /var/www/html/occ app:enable files_external

if php /var/www/html/occ files_external:list --output=json | grep -q "\"$MOUNT_NAME\""; then
  echo "External storage '$MOUNT_NAME' already exists, skipping"
  exit 0
fi

MOUNT_ID=$(php /var/www/html/occ files_external:create "$MOUNT_NAME" local null::null \
  -c datadir="$MOUNT_PATH")
php /var/www/html/occ files_external:applicable "$MOUNT_ID" --add-group="$MOUNT_GROUP"
php /var/www/html/occ files_external:option "$MOUNT_ID" enable_sharing true
