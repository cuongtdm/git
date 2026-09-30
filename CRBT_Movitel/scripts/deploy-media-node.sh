#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
NODE_IP="${1:?Usage: $0 <media-node-ip>}"
OVERLAY="$ROOT/config/media-$NODE_IP"
DEST=/u01/crbt-movitel
BACKUP=/u01/crbt-movitel/backup/media-$(date +%Y%m%d_%H%M%S)

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
[[ -d "$OVERLAY" ]] || { echo "Unknown media node: $NODE_IP" >&2; exit 1; }
mkdir -p "$BACKUP" "$DEST" \
    "$DEST/log/mediactrl_rt"/{main,flow_expire,processing,ipcserver_for_media} \
    "$DEST/log/error/mediactrl_rt/alarm" \
    "$DEST/log/mediaserver_pcm" "$DEST/log/local_rt" \
    "$DEST/cdr"/{mediactrl_rt,export/mediactrl_rt/ccu,export/mediactrl_rt/cps} \
    "$DEST/ramdisk"
for component in mediactrl_rt mediaserver_pcm local_rt; do
    [[ ! -d "$DEST/$component" ]] || cp -a "$DEST/$component" "$BACKUP/"
done
cp -a "$ROOT/payload/mediactrl_rt" "$DEST/"
cp -a "$ROOT/payload/mediaserver_pcm" "$DEST/"
cp -a "$ROOT/payload/local_rt" "$DEST/"
cp -a "$OVERLAY/mediactrl_rt/config/." "$DEST/mediactrl_rt/config/"
cp -a "$OVERLAY/mediaserver_pcm/config/." "$DEST/mediaserver_pcm/config/"
mkdir -p "$DEST/mediaserver_pcm/media/local"
install -D -m 0644 "$OVERLAY/local_rt/crbt-local-rt.env" "$DEST/local_rt/crbt-local-rt.env"
install -D -m 0644 "$ROOT/payload/local_rt/crbt-local-rt.service" /etc/systemd/system/crbt-local-rt.service
chmod 755 "$DEST/mediactrl_rt/bin/"*.sh "$DEST/mediaserver_pcm/bin/"*.sh \
    "$DEST/mediaserver_pcm/bin/mediaserver" "$DEST/local_rt/local_rt.py"
systemctl daemon-reload
echo "Media node $NODE_IP installed. Backup: $BACKUP"
echo "Upload WAV files to $DEST/mediaserver_pcm/media/local/ before call testing."
