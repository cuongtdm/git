#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SOURCE="$ROOT/payload/swapfile_ringtone"
DEST=/u01/crbt-movitel/swapfile_ringtone
BACKUP=/u01/crbt-movitel/backup/swapfile-$(date +%Y%m%d_%H%M%S)

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
[[ -d "$SOURCE" ]] || { echo "Missing payload: $SOURCE" >&2; exit 1; }
mkdir -p /u01/crbt-movitel/backup /u01/crbt-movitel/ramdisk /u01/crbt-movitel/log/swapfile_ringtone
if [[ -d "$DEST" ]]; then cp -a "$DEST" "$BACKUP"; fi
mkdir -p "$DEST"
cp -a "$SOURCE/." "$DEST/"
chmod 755 "$DEST/bin/"*.sh
install -D -m 0644 "$ROOT/swapfile-ringtone.service" /etc/systemd/system/swapfile-ringtone.service
systemctl daemon-reload
echo "Swapfile installed. Backup: $BACKUP"
