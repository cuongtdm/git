#!/usr/bin/env bash
set -euo pipefail
if ! ss -lnt 2>/dev/null | grep -q ':9981'; then
    echo "WARNING: swapfile is not listening on TCP 9981; mediactrl ringtone copy may fail." >&2
fi
if [[ ! -f /u01/crbt-movitel/mediaserver_pcm/media/local/song-1.wav ]]; then
    echo "WARNING: fallback song-1.wav is missing from media/local." >&2
fi
systemctl enable --now crbt-local-rt.service
cd /u01/crbt-movitel/mediactrl_rt/bin && ./start.sh
sleep 2
cd /u01/crbt-movitel/mediaserver_pcm/bin && ./start.sh
echo "Started local_rt, mediactrl_rt and mediaserver_pcm."
