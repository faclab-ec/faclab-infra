#!/bin/sh
# The copy of the object storage outside the server (S8.3): the entrypoint of the objects-backup
# service of compose.yaml, in the rclone image. Garage's bucket (authorized XML, RIDE, logos) goes to
# a bucket with versioning and Object Lock through rclone crypt: contents and names are encrypted on
# the server before they leave. Run it through scripts/backups.sh or stack.sh restore-objects.
#
#   objects-backup.sh copy      every object missing or changed in the archive (rclone copy: nothing
#                               is ever deleted there, a changed object becomes a new version)
#   objects-backup.sh recent    the same, only objects written in the last 24 hours, without listing
#                               the whole archive: the frequent run
#   objects-backup.sh restore   the latest version of every object back into Garage
#   objects-backup.sh count     objects and bytes on each side, as one line of JSON
set -eu

# The crypt remote over the archive. rclone wants the passwords obscured; they come in plain from
# the secrets and are obscured here, through stdin, never in a command line
RCLONE_CONFIG_SECURE_TYPE=crypt
RCLONE_CONFIG_SECURE_REMOTE="archive:$ARCHIVE_BUCKET"
RCLONE_CONFIG_SECURE_PASSWORD="$(printf '%s' "$CRYPT_PASSWORD" | rclone obscure -)"
RCLONE_CONFIG_SECURE_PASSWORD2="$(printf '%s' "$CRYPT_SALT" | rclone obscure -)"
export RCLONE_CONFIG_SECURE_TYPE RCLONE_CONFIG_SECURE_REMOTE RCLONE_CONFIG_SECURE_PASSWORD \
  RCLONE_CONFIG_SECURE_PASSWORD2
unset CRYPT_PASSWORD CRYPT_SALT

# Most S3-compatible services take bucket/key paths (BACKUP_S3_URI_STYLE)
if [ "${ARCHIVE_URI_STYLE:-path}" = host ]; then
  export RCLONE_CONFIG_ARCHIVE_FORCE_PATH_STYLE=false
else
  export RCLONE_CONFIG_ARCHIVE_FORCE_PATH_STYLE=true
fi
# Only a stand-in with a self-signed certificate turns it off (BACKUP_S3_VERIFY_TLS=n)
if [ "${ARCHIVE_VERIFY_TLS:-y}" = n ]; then
  export RCLONE_NO_CHECK_CERTIFICATE=true
fi

source="garage:$SOURCE_BUCKET"
# A summary at the end, the errors and each object copied
set -- "${1:-copy}"
flags="--stats-one-line --stats-log-level NOTICE --stats 0 --log-level INFO --checkers 8 --transfers 4 --retries 3"

case "$1" in
  copy)
    # shellcheck disable=SC2086 # one flag per word
    exec rclone copy "$source" secure: $flags
    ;;
  recent)
    # shellcheck disable=SC2086
    exec rclone copy "$source" secure: $flags --max-age 24h --no-traverse
    ;;
  restore)
    # shellcheck disable=SC2086
    exec rclone copy secure: "$source" $flags
    ;;
  count)
    printf '{"garage": %s, "archive": %s}\n' "$(rclone size --json "$source")" "$(rclone size --json secure:)"
    ;;
  *)
    echo "objects-backup.sh: unknown command $1 (copy, recent, restore, count)" >&2
    exit 1
    ;;
esac
