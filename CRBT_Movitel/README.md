# CRBT Movitel

Topology in this bundle:

- OpenSIPS LB: `10.229.4.20`, `10.229.4.21`
- Media: `10.229.4.20`, `10.229.4.21`, `10.229.4.22`
- Media SIP endpoint: `<media-ip>:5062`
- Local RT selector: `127.0.0.1:8081` on every media node

## Before building

Copy `inventory.example.json` to `inventory.json`, then edit it before the first build. `inventory.json` is intentionally excluded from Git because it contains deployment credentials.

- `mysql.password`: required for both OpenSIPS nodes.
- `localRt.dbHost`, `dbName`, `dbUser`, `dbPassword`: required when local RT must select songs from `album_item`/`song`. Blank values deliberately play the configured fallback song.
- `mediaCtrl.apsServerUrl`: endpoint used only for DTMF buy/copy-song flows. Change it to the Movitel endpoint before enabling that feature.

Build the deployable directory and zip:

```powershell
powershell -ExecutionPolicy Bypass -File .\build-package.ps1 -Zip
```

The output is `dist/` and `dist.zip`. It contains one shared media runtime payload plus node-specific config overlays.

## Deploy media nodes

Extract `dist.zip` to `/u01/crbt-movitel` on each media node. Runtime, config,
ramdisk and logs all remain below that directory.

```bash
cd /u01/crbt-movitel
chmod 755 scripts/*.sh
sudo ./scripts/deploy-media-node.sh 10.229.4.20
sudo ./scripts/start-media-node.sh
```

Repeat with `.21` and `.22` on their respective hosts. Put Movitel WAV files in `/u01/crbt-movitel/mediaserver_pcm/media/local/` after deployment.

## Deploy OpenSIPS

On `.20` and `.21`, install the config matching the local host:

```bash
cd /u01/crbt-movitel
sudo ./scripts/deploy-opensips-node.sh 10.229.4.20
```

Import `config/mysql/load_balancer_seed.sql` once into the `opensip` database. The bundle installs a separate `opensips-movitel` service using config below `/u01/crbt-movitel`; stop the old service before starting it:

```bash
mysql -h 10.229.4.25 -u opensip -p opensip < config/mysql/load_balancer_seed.sql
sudo systemctl disable --now opensips
sudo systemctl enable --now opensips-movitel
```

The OpenSIPS config suppresses PCM `180 Ringing`, leaving the intended `100 Trying -> 200 OK -> RTP` flow.
