#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
NODE_IP="${1:?Usage: $0 <opensips-node-ip>}"
SOURCE="$ROOT/config/opensips-$NODE_IP/opensips.cfg"
DEST=/u01/crbt-movitel/opensips/opensips.cfg
OPENSIPS_BIN="$(command -v opensips || true)"
MODULE_FILE="$(find /usr/local /usr /lib -type f -name signaling.so 2>/dev/null | head -n 1)"
[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
[[ -f "$SOURCE" ]] || { echo "Unknown OpenSIPS node: $NODE_IP" >&2; exit 1; }
[[ -n "$OPENSIPS_BIN" ]] || { echo "opensips binary is not in PATH." >&2; exit 1; }
[[ -n "$MODULE_FILE" ]] || { echo "Cannot locate signaling.so; install OpenSIPS modules first." >&2; exit 1; }
install -d -m 0755 /u01/crbt-movitel/backup
[[ ! -f "$DEST" ]] || cp -a "$DEST" "/u01/crbt-movitel/backup/opensips.cfg.$(date +%Y%m%d_%H%M%S)"
install -D -m 0644 "$SOURCE" "$DEST"
MODULE_DIR="$(dirname "$MODULE_FILE")"
sed -i "s|^mpath=.*|mpath=\"$MODULE_DIR/\"|" "$DEST"
install -d -m 0755 /u01/crbt-movitel/log/opensips
install -D -m 0644 "$ROOT/scripts/30-crbt-movitel-opensips.conf" /etc/rsyslog.d/30-crbt-movitel-opensips.conf
install -D -m 0644 "$ROOT/scripts/opensips-movitel.service" /etc/systemd/system/opensips-movitel.service
systemctl reload rsyslog 2>/dev/null || true
systemctl daemon-reload
"$OPENSIPS_BIN" -C -f "$DEST"
echo "OpenSIPS config installed for $NODE_IP. Start opensips-movitel after importing MySQL seed."
