#!/bin/sh
# Mount the qBittorrent downloads folder as external storage so any
# downloaded file (not just photos, unlike Immich) can get a public
# Nextcloud share link. Restricted to the "admin" group.
# This runs once, right after a fresh Nextcloud installation.

set -eu

OCC="php /var/www/html/occ"
MOUNT_NAME="Downloads"
MOUNT_PATH="/mnt/qbittorrent-downloads"
MOUNT_GROUP="admin"

if [ ! -d "$MOUNT_PATH" ]; then
  echo "$MOUNT_PATH not mounted into this container, skipping external storage setup"
  exit 0
fi

$OCC app:enable files_external

# The mount id for $MOUNT_NAME, or empty. Parsed with php (jq is not in this
# image) rather than grepped, so a match yields the id the reconciliation below
# needs — an existence-only check cannot repair a half-created mount.
existing_mount_id() {
  $OCC files_external:list --output=json | php -r '
    $rows = json_decode(stream_get_contents(STDIN), true);
    if (!is_array($rows)) { exit(0); }
    foreach ($rows as $row) {
        if (ltrim($row["mount_point"] ?? "", "/") === $argv[1]) {
            echo $row["mount_id"] ?? "";
            exit(0);
        }
    }
  ' -- "$MOUNT_NAME"
}

MOUNT_ID="$(existing_mount_id)"
if [ -n "$MOUNT_ID" ]; then
  echo "External storage '$MOUNT_NAME' already exists (id $MOUNT_ID), reconciling"
else
  MOUNT_ID="$($OCC files_external:create "$MOUNT_NAME" local null::null \
    -c datadir="$MOUNT_PATH")"
fi

# occ prints the new mount's numeric id on stdout. Validated before use: an
# empty or non-numeric value here means create failed, and passing it on would
# leave a mount applicable to nobody with sharing off — exactly the two
# settings this hook exists to apply, and the existence check above would then
# report success on every later run.
case "$MOUNT_ID" in
  ''|*[!0-9]*)
    echo "files_external:create did not return a mount id (got: '$MOUNT_ID')" >&2
    exit 1
    ;;
esac

# Both are idempotent, so they also repair a mount left half-configured by an
# earlier failed run.
$OCC files_external:applicable "$MOUNT_ID" --add-group="$MOUNT_GROUP"
$OCC files_external:option "$MOUNT_ID" enable_sharing true
echo "External storage '$MOUNT_NAME' (id $MOUNT_ID) applicable to group '$MOUNT_GROUP', sharing enabled"
