#!/bin/sh
# Print the five values that open the off-site backup, as two sheets to cut
# apart and store in two different places.
#
# Why five values and not the whole .env: the S3 repository already holds .env
# at /userdata/pi-web-env/.env, so these five are the only thing that has to
# survive off the machine - and unlike .env, they change almost never. Keeping
# a few near-static strings on paper needs no tooling, no passphrase to
# remember, and no upload credential living on the machine being protected.
#
# Read from config.json, not .env: that is the file Backrest actually feeds to
# restic, so it is the operative truth. Taking it as the single source is why
# this script has no drift check - there is no second source to disagree with.
#
# Verification is not optional. It runs restic from a throwaway container with
# nothing mounted, which is the state you would really be restoring in, and it
# answers "are these the right values" directly. Every indirect check this
# script used to carry was a worse proxy for this one test.
set -eu

. "$(dirname "$0")/lib.sh"

# These are the keys to every secret in the stack.
umask 077

CONFIG="$PROJECT_DIR/config/backrest/config.json"
[ -r "$CONFIG" ] || die "cannot read $CONFIG - has the stack ever started?"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v docker >/dev/null 2>&1 || die "docker is required (verification is mandatory)"

repo="$(jq -ec '.repos[]|select(.id=="s3")' "$CONFIG")" || die "no 's3' repository in $CONFIG"
field() { printf '%s' "$repo" | jq -r "$1"; }
env_of() { field ".env[]?|select(startswith(\"$1=\"))|sub(\"^[^=]*=\";\"\")"; }

URI="$(field '.uri')"
PW="$(field '.password')"
AK="$(env_of AWS_ACCESS_KEY_ID)"
SK="$(env_of AWS_SECRET_ACCESS_KEY)"
RG="$(env_of AWS_DEFAULT_REGION)"
for f in "uri:$URI" "password:$PW" "AWS_ACCESS_KEY_ID:$AK" "AWS_SECRET_ACCESS_KEY:$SK"; do
    [ -n "${f#*:}" ] || die "the 's3' repository in $CONFIG has no ${f%%:*}"
done

# mktemp, not a fixed path: created atomically at 0600 under a name nobody can
# predict. That is the whole reason this script takes no output argument - a
# caller-supplied path needed a guard against landing inside the backup, and
# the guard was defeatable by a symlink.
ENVFILE="$(mktemp)"
trap 'rm -f "$ENVFILE"' EXIT INT TERM

# --env-file rather than -e: -e puts every secret in the host process table,
# readable by any local user through /proc/<pid>/cmdline for the length of the
# call.
printf 'RESTIC_REPOSITORY=%s\nRESTIC_PASSWORD=%s\nAWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\nAWS_DEFAULT_REGION=%s\n' \
    "$URI" "$PW" "$AK" "$SK" "$RG" > "$ENVFILE"

log "verifying the five values against the live repository..."
if ! out="$(docker run --rm --env-file "$ENVFILE" --entrypoint restic \
        pi-backrest:local snapshots --latest 1 2>&1)"; then
    # Keep restic's message: a locked repo, a wrong region and a wrong password
    # all fail here, and this is the one place it matters which.
    die "the five values did NOT open the repository, so this sheet would be useless:
$out"
fi
log "verified: these five values open the repository on their own"

# Created only once verification has passed, so a failed run leaves nothing
# behind and no half-written sheet can ever be mistaken for a good one.
OUT="$(mktemp)"
CODE="PW-$(LC_ALL=C tr -dc 'A-Z0-9' </dev/urandom | head -c4)"

cat > "$OUT" <<EOF
================================================================================
  SHEET A  --  STORAGE ACCESS                        made $(date +%Y-%m-%d)
================================================================================

  Repository   $URI
  Region       $RG
  Access key   $AK
  Secret key   $SK

  The decryption password is on sheet $CODE, stored somewhere else.
  Both are needed to read anything.

  This sheet alone cannot read the backup, but it CAN delete it: the key
  above may erase, and the bucket has no versioning. Store it carefully.

--------------------------------------------------------------------------------
  TO RESTORE, on any computer, after installing restic (restic.net):

    export RESTIC_REPOSITORY="$URI"
    export AWS_ACCESS_KEY_ID="$AK"
    export AWS_SECRET_ACCESS_KEY="$SK"
    export AWS_DEFAULT_REGION="$RG"
    export RESTIC_PASSWORD="<from sheet $CODE>"

    restic snapshots

  Just the server's password file, a few KB, enough to rebuild everything:

    restic restore latest --target /tmp/r --include /userdata/pi-web-env
    -> /tmp/r/userdata/pi-web-env/.env

  Everything, ~250 GB. Needs a real disk with that much free -- not /tmp,
  which is usually RAM and would die partway:

    restic restore latest --target /mnt/restore

--------------------------------------------------------------------------------
  After rotating the S3 key or the repository password, run
  "make recovery-kit" and reprint BOTH sheets: the pairing code changes
  every time, so replacing one half alone leaves a mismatched pair.

  Once a year, check that "restic snapshots" still answers.

  Do not store this sheet with sheet $CODE.
================================================================================




%%%%%%%%%%%%%%%%%%%%%%%%%  CUT HERE -- STORE APART  %%%%%%%%%%%%%%%%%%%%%%%%%%%%




================================================================================
  $CODE
================================================================================

    $PW

  Second half of a pair. Useless on its own, and it names nothing.
  The other sheet says what to do with it. Do not store them together.
================================================================================
EOF

log "kit written to $OUT (pairing code $CODE)"
log "print it, cut along the %%%% line, store the two halves apart, then:"
log "    shred -u $OUT"
