# CRBT Movitel Swapfile Ringtone Cache

This package installs the local `swapfile_ringtone` module on one media node.
It receives mediactrl IPC on TCP `9981`, copies selected WAV files to
`/u01/crbt-movitel/ramdisk`, and exposes the existing HTTP service on TCP `9982`.

The module must run on every media node (`10.229.4.20`, `.21`, `.22`) because
each node's `mediactrl_rt` is configured for local `127.0.0.1:9981`.

## Install

```bash
mkdir -p /u01/crbt-movitel-swapfile
unzip -oq /u01/crbt-movitel-swapfile.zip -d /u01/crbt-movitel-swapfile
cd /u01/crbt-movitel-swapfile
chmod 755 scripts/*.sh
sudo ./scripts/deploy-swapfile.sh
sudo systemctl enable --now swapfile-ringtone.service
```

## Verify

```bash
sudo systemctl status swapfile-ringtone.service --no-pager
sudo ss -lntp | grep -E ':(9981|9982)\b'
sudo tail -f /u01/crbt-movitel/log/swapfile_ringtone/main.log
```

Start swapfile before `mediactrl_rt` and `mediaserver_pcm`.
