#!/bin/sh
# Mount the qBittorrent downloads folder as external storage so any
# downloaded file (not just photos, unlike Immich) can get a public
# Nextcloud share link. Restricted to the "admin" group.
# This runs once, right after a fresh Nextcloud installation.
#
# Never exits non-zero: the nextcloud image's entrypoint aborts the container
# when a post-installation hook fails, and these hooks are never re-run (the
# version stamp lands before they do) — so a failure here would leave a fresh
# install permanently unable to start over a convenience mount. set -u only;
# every step is checked explicitly and failure logs a warning and exits 0.

set -u

OCC="php /var/www/html/occ"
MOUNT_NAME="Downloads"
MOUNT_PATH="/mnt/qbittorrent-downloads"
MOUNT_GROUP="admin"

warn_and_exit() {
  echo "WARNING: $* — skipping external storage setup (re-run this hook manually via docker exec)" >&2
  exit 0
}

if [ ! -d "$MOUNT_PATH" ]; then
  echo "$MOUNT_PATH not mounted into this container, skipping external storage setup"
  exit 0
fi

$OCC app:enable files_external || warn_and_exit "could not enable files_external"

# The mount id for $MOUNT_NAME, or empty. Parsed with php (jq is not in this
# image); any warning noise occ prints before the JSON array is stripped by
# seeking to the first '['. An existence-only check could not repair a
# half-created mount, which is why the id is resolved rather than grepped.
existing_mount_id() {
  $OCC files_external:list --output=json 2>/dev/null | php -r '
    $in = stream_get_contents(STDIN);
    $start = strpos($in, "[");
    $rows = $start === false ? null : json_decode(substr($in, $start), true);
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
  # With the default plain output this prints "Storage created with id N",
  # not a bare number — only the trailing integer is the id.
  CREATED="$($OCC files_external:create "$MOUNT_NAME" local null::null \
    -c datadir="$MOUNT_PATH")" || warn_and_exit "files_external:create failed"
  MOUNT_ID="$(printf '%s' "$CREATED" | grep -oE '[0-9]+' | tail -n1)"
  # A create that printed no id: fall back to re-resolving from the list.
  [ -n "$MOUNT_ID" ] || MOUNT_ID="$(existing_mount_id)"
fi

case "$MOUNT_ID" in
  ''|*[!0-9]*)
    warn_and_exit "could not determine the mount id for '$MOUNT_NAME' (create printed: '${CREATED:-}')"
    ;;
esac

# Both are idempotent, so they also repair a mount left half-configured by an
# earlier failed run.
$OCC files_external:applicable "$MOUNT_ID" --add-group="$MOUNT_GROUP" \
  || warn_and_exit "files_external:applicable failed for mount $MOUNT_ID"
$OCC files_external:option "$MOUNT_ID" enable_sharing true \
  || warn_and_exit "files_external:option enable_sharing failed for mount $MOUNT_ID"
# files_external:create leaves this unset, so the mount inherits the system
# value (0 = never re-stat) and files written by qBittorrent after the first
# scan stay invisible. The system value cannot fix it — it excludes external
# storage — so it has to be set per mount, as the web UI does.
$OCC files_external:option "$MOUNT_ID" filesystem_check_changes 1 \
  || warn_and_exit "files_external:option filesystem_check_changes failed for mount $MOUNT_ID"
echo "External storage '$MOUNT_NAME' (id $MOUNT_ID) applicable to group '$MOUNT_GROUP', sharing enabled, change detection on"
