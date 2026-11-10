#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then
  echo "Usage: sh scripts/check-backup.sh /secure/path/to/backup.dump" >&2
  exit 2
fi
target="$1"
test -r "$target" || { echo "Cannot read archive" >&2; exit 1; }
pg_restore --list "$target" >/dev/null
if [ -f "$target.sha256" ]; then
  (cd "$(dirname "$target")" && sha256sum -c "$(basename "$target").sha256")
fi
echo "Archive structure and available checksum verified. This does NOT replace restore testing."
