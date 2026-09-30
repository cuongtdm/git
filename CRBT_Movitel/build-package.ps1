param(
    [string]$InventoryPath = (Join-Path $PSScriptRoot "inventory.json"),
    [string]$OutputPath = (Join-Path $PSScriptRoot "dist"),
    [switch]$Zip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Utf8File([string]$Path, [string]$Content) {
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Copy-Runtime([string]$Source, [string]$Destination, [string[]]$ExcludeNames) {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | Where-Object { $ExcludeNames -notcontains $_.Name } |
        Copy-Item -Destination $Destination -Recurse -Force
}

function Build-OpenSipsConfig($NodeIp, $Inv) {
$dbPassword = [Uri]::EscapeDataString([string]$Inv.mysql.password)
@"
# CRBT Movitel OpenSIPS 3.2 media load balancer
log_level=3
xlog_level=3
log_stderror=no
log_facility=LOG_LOCAL3
udp_workers=8

socket=udp:$NodeIp`:5060
socket=tcp:$NodeIp`:5060
mpath="$($Inv.opensipsModulePath)"

loadmodule "signaling.so"
loadmodule "sl.so"
loadmodule "cfgutils.so"
modparam("cfgutils", "shvset", "servicestatus=i:1")
loadmodule "tm.so"
modparam("tm", "fr_timeout", 5)
modparam("tm", "fr_inv_timeout", 30)
modparam("tm", "restart_fr_on_each_reply", 0)
loadmodule "rr.so"
modparam("rr", "append_fromtag", 1)
loadmodule "maxfwd.so"
loadmodule "sipmsgops.so"
loadmodule "mi_fifo.so"
modparam("mi_fifo", "fifo_name", "/run/opensips/opensips_fifo")
modparam("mi_fifo", "fifo_mode", 0660)
loadmodule "db_mysql.so"
loadmodule "acc.so"
modparam("acc", "early_media", 0)
modparam("acc", "report_cancels", 0)
modparam("acc", "log_facility", "LOG_LOCAL3")
loadmodule "path.so"
loadmodule "options.so"
modparam("options", "support", "100rel")
loadmodule "dialog.so"
modparam("dialog", "dlg_match_mode", 1)
modparam("dialog", "default_timeout", 21600)
modparam("dialog", "db_mode", 0)
loadmodule "load_balancer.so"
modparam("load_balancer", "db_url", "mysql://$($Inv.mysql.user):$dbPassword@$($Inv.mysql.host)/$($Inv.mysql.database)")
modparam("load_balancer", "probing_method", "OPTIONS")
modparam("load_balancer", "probing_interval", 30)
loadmodule "proto_udp.so"
loadmodule "proto_tcp.so"
loadmodule "uac.so"
modparam("uac", "restore_mode", "auto")
loadmodule "textops.so"

route {
    if (!mf_process_maxfwd_header(10)) { send_reply(483, "Too Many Hops"); exit; }
    if (has_totag()) {
        if (is_method("ACK") && t_check_trans()) { t_relay(); exit; }
        if (!loose_route()) { send_reply(404, "Not here"); exit; }
        route(RELAY); exit;
    }
    if (is_method("CANCEL")) { if (t_check_trans()) { t_relay(); } exit; }
    if (is_method("OPTIONS")) { options_reply(); exit; }
    if (!is_method("INVITE")) { send_reply(405, "Method Not Allowed"); exit; }
    if (`$rU == NULL) { send_reply(484, "Address Incomplete"); exit; }
    if (!lb_start($($Inv.service.loadBalancerGroup), "$($Inv.service.resourceName)")) {
        send_reply(486, "All destination busy"); exit;
    }
    record_route();
    t_on_reply("DROP_PCM_180");
    t_on_failure("GW_FAILOVER");
    route(RELAY);
}
route[RELAY] { if (!t_relay()) { sl_reply_error(); } exit; }
failure_route[GW_FAILOVER] {
    if (t_was_cancelled()) { exit; }
    if (t_check_status("(408)|([56][0-9][0-9])")) {
        if (lb_next()) { t_on_failure("GW_FAILOVER"); t_relay(); exit; }
        send_reply(500, "All media nodes are down");
    }
}
onreply_route[DROP_PCM_180] { if (t_check_status("180")) { drop(); } }
"@
}

$repo = Split-Path -Parent $PSScriptRoot
$inv = Get-Content -LiteralPath $InventoryPath -Raw | ConvertFrom-Json
$runtimeRoot = "/u01/crbt-movitel"
if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Recurse -Force }
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

# Shared payload is deployed unchanged on every media node.
Copy-Runtime (Join-Path $repo "mediactrl_rt") (Join-Path $OutputPath "payload\mediactrl_rt") @("nohup.out", ".MySCMServerInfo")
Copy-Runtime (Join-Path $repo "mediaserver_pcm") (Join-Path $OutputPath "payload\mediaserver_pcm") @("screenlog.0")
Copy-Runtime (Join-Path $repo "deployment_single_node\local_rt") (Join-Path $OutputPath "payload\local_rt") @("crbt-sip-20260907-133305.pcap")

# Keep every runtime file below the Movitel project root.
$localRtProgram = Join-Path $OutputPath "payload\local_rt\local_rt.py"
Write-Utf8File $localRtProgram ((Get-Content $localRtProgram -Raw).Replace("/opt/vrbt/bin/mediaserver_pcm/media/local", "$runtimeRoot/mediaserver_pcm/media/local"))
Write-Utf8File (Join-Path $OutputPath "payload\local_rt\crbt-local-rt.service") @"
[Unit]
Description=CRBT Movitel local RT selector
After=network.target

[Service]
Type=simple
EnvironmentFile=-$runtimeRoot/local_rt/crbt-local-rt.env
ExecStart=/bin/sh -c 'exec /usr/bin/env python3 $runtimeRoot/local_rt/local_rt.py >> $runtimeRoot/log/local_rt/local_rt.log 2>&1'
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
"@
$mediaCtrlEnv = Join-Path $OutputPath "payload\mediactrl_rt\bin\mediactrl_env.sh"
Write-Utf8File $mediaCtrlEnv ((Get-Content $mediaCtrlEnv -Raw).Replace("nohup java -cp ../lib/*:mediactrl_rt.jar com.elcom.voicegw.mediactrl.MediaCtrlMain `$1 mediactrl_rt`$1 ../config/ &", "nohup java -cp ../lib/*:mediactrl_rt.jar com.elcom.voicegw.mediactrl.MediaCtrlMain `$1 mediactrl_rt`$1 ../config/ >> $runtimeRoot/log/mediactrl_rt/stdout.log 2>&1 &"))
$mediaServerRun = Join-Path $OutputPath "payload\mediaserver_pcm\bin\run.sh"
Write-Utf8File $mediaServerRun ((Get-Content $mediaServerRun -Raw).Replace("/opt/vrbt/bin/mediaserver_pcm", "$runtimeRoot/mediaserver_pcm").Replace("/opt/vrbt/bin/mediaserver/bin/mediaserver", "$runtimeRoot/mediaserver_pcm/bin/mediaserver").Replace("/opt/vrbt", $runtimeRoot))

# The shared payload must be runnable on its own, not only after a node overlay is applied.
$payloadCtrlCfg = Join-Path $OutputPath "payload\mediactrl_rt\config"
$payloadPcmCfg = Join-Path $OutputPath "payload\mediaserver_pcm\config"
$payloadCtrlLog = Join-Path $payloadCtrlCfg "log4j.mediactrl.xml"
Write-Utf8File $payloadCtrlLog ((Get-Content $payloadCtrlLog -Raw).Replace("/opt/vrbt/log", "$runtimeRoot/log").Replace("/u02/log", "$runtimeRoot/log").Replace("/u02/cdr", "$runtimeRoot/cdr"))
$payloadRtClient = Join-Path $payloadCtrlCfg "rt_client.cfg"
Write-Utf8File $payloadRtClient ((Get-Content $payloadRtClient -Raw).Replace("RT_FILE_DIR = /u02", "RT_FILE_DIR = $runtimeRoot/ramdisk"))
$payloadController = Join-Path $OutputPath "payload\mediactrl_rt\bin\controller.sh"
Write-Utf8File $payloadController ((Get-Content $payloadController -Raw).Replace("/opt/vrbt/log", "$runtimeRoot/log"))
$payloadPcmLog = Join-Path $payloadPcmCfg "mediaserver.log4cxx.xml"
Write-Utf8File $payloadPcmLog ((Get-Content $payloadPcmLog -Raw).Replace("/opt/vrbt/log", "$runtimeRoot/log"))
$payloadPcmMain = Join-Path $payloadPcmCfg "mediaserver.cfg"
Write-Utf8File $payloadPcmMain ((Get-Content $payloadPcmMain -Raw).Replace("/opt/vrbt/bin/mediaserver2/media", "$runtimeRoot/mediaserver_pcm/media").Replace("/opt/vrbt/bin/mediaserver_pcm/media", "$runtimeRoot/mediaserver_pcm/media"))
$payloadLocalEnv = Join-Path $OutputPath "payload\local_rt\crbt-local-rt.env"
Write-Utf8File $payloadLocalEnv ((Get-Content $payloadLocalEnv -Raw).Replace("/opt/vrbt/bin/mediaserver_pcm/media/local", "$runtimeRoot/mediaserver_pcm/media/local"))

# Runtime stdout files are transient and must not be shipped as historical logs.
Remove-Item -LiteralPath (Join-Path $OutputPath "payload\mediactrl_rt\bin\nohup.out") -Force -ErrorAction SilentlyContinue

foreach ($node in $inv.opensipsNodes) {
    Write-Utf8File (Join-Path $OutputPath "config\opensips-$node\opensips.cfg") (Build-OpenSipsConfig $node $inv)
}

$sqlRows = foreach ($node in $inv.mediaNodes) {
    "($($inv.service.loadBalancerGroup), 'sip:$($node.ip):$($inv.service.sipPort)', '$($inv.service.resourceName)=300', 2, '', 'movitel-media-$($node.session)')"
}
$sql = "DELETE FROM load_balancer WHERE group_id = $($inv.service.loadBalancerGroup) AND resources LIKE '$($inv.service.resourceName)=%';`n`n"
$sql += "INSERT INTO load_balancer (group_id, dst_uri, resources, probe_mode, attrs, description) VALUES`n" + ($sqlRows -join ",`n") + ";`n"
Write-Utf8File (Join-Path $OutputPath "config\mysql\load_balancer_seed.sql") $sql

$transportBase = Get-Content (Join-Path $repo "mediaserver_pcm\config\Transport.json") -Raw | ConvertFrom-Json
$accountBase = Get-Content (Join-Path $repo "mediaserver_pcm\config\account.json") -Raw | ConvertFrom-Json
$mediaServerCfg = (Get-Content (Join-Path $repo "mediaserver_pcm\config\mediaserver.cfg") -Raw).Replace("/opt/vrbt/bin/mediaserver2/media", "/opt/vrbt/bin/mediaserver_pcm/media")
$swapCfg = (Get-Content (Join-Path $repo "mediactrl_rt\config\ipcclient_to_swapfile_rt.cfg") -Raw).Replace("ip = 127.0.0.1", "ip = $($inv.mediaCtrl.swapfileHost)").Replace("port = 9981", "port = $($inv.mediaCtrl.swapfilePort)")

foreach ($node in $inv.mediaNodes) {
    $root = Join-Path $OutputPath "config\media-$($node.ip)"
    $ctrl = Join-Path $root "mediactrl_rt\config"
    $pcm = Join-Path $root "mediaserver_pcm\config"
    New-Item -ItemType Directory -Force -Path $ctrl, $pcm | Out-Null
    Copy-Item (Join-Path $repo "mediactrl_rt\config\*") $ctrl -Recurse -Force
    Copy-Item (Join-Path $repo "mediaserver_pcm\config\*") $pcm -Recurse -Force

    # Each MediaCtrl owns one media-server IPC identity. Rewriting every
    # legacy [service] block would create duplicate names and prevent startup.
    Write-Utf8File (Join-Path $ctrl "ipcserver_for_media.cfg") @"
[server]
  listen_port = 7200
  server_processing_number = 16
  max_connection_of_all_client = 200
  receiving_timeout_s = 60
  sending_timeout_s = 120
  enquire_link_sending_period_s = 15
  max_unbound_period_s = 30

[service]
  name = $($node.session)
  password = $($node.session)
  ip_address = *,
  max_connection = 5
"@
    Write-Utf8File (Join-Path $ctrl "ipcclient_to_swapfile_rt.cfg") $swapCfg
    $ctrlLog = (Get-Content (Join-Path $ctrl "log4j.mediactrl.xml") -Raw).Replace("/opt/vrbt/log", "$runtimeRoot/log").Replace("/u02/log", "$runtimeRoot/log").Replace("/u02/cdr", "$runtimeRoot/cdr")
    Write-Utf8File (Join-Path $ctrl "log4j.mediactrl.xml") $ctrlLog
    Write-Utf8File (Join-Path $ctrl "rt_client.cfg") @"
EXTEND_HOST = $($inv.mediaCtrl.rtHost)
EXTEND_USER_AGENT = CMS/0309000406
EXTEND_CONID_FORMAT = 1-4-178-3825-?????????????
EXTEND_CMS_HOST_IP = 127.0.0.1
EXTEND_PARAMS = caller=@CALLER@&called=@CALLED@&connId=@CONID@&cms=13.8
CONNECT_TIMEOUT_MS = 15000
SOCKET_TIMEOUT_MS = 120000
SELECT_AUDIO = vxml > form[id=playMultiTime] > field[name=fieldvar] > prompt[playfromoffsetexpr=offset] > audio
SELECT_ITEMID = vxml > var[name=ITEMID]
RT_FILE_DIR = $runtimeRoot/ramdisk
"@
    Write-Utf8File (Join-Path $ctrl "aps_client.cfg") "APS_SERVER_URL = $($inv.mediaCtrl.apsServerUrl)`nCONNECT_TIMEOUT_MS = 1000`nSOCKET_TIMEOUT_MS = 5000`n"

    $transport = $transportBase | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $transport.TransportConfig.port = [int]$inv.service.sipPort
    $transport.TransportConfig.boundAddress = $node.ip
    Write-Utf8File (Join-Path $pcm "Transport.json") ($transport | ConvertTo-Json -Depth 30)
    $account = $accountBase | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $account.AccountConfig.idUri = "sip:$($node.ip):$($inv.service.sipPort)"
    $account.AccountConfig.AccountMediaConfig.TransportConfig.port = [int]$inv.service.rtpStartPort
    $account.AccountConfig.AccountMediaConfig.TransportConfig.portRange = [int]$inv.service.rtpPortRange
    $account.AccountConfig.AccountMediaConfig.TransportConfig.boundAddress = $node.ip
    Write-Utf8File (Join-Path $pcm "account.json") ($account | ConvertTo-Json -Depth 30)
    $pcmLog = (Get-Content (Join-Path $pcm "mediaserver.log4cxx.xml") -Raw).Replace("/opt/vrbt/log", "$runtimeRoot/log")
    Write-Utf8File (Join-Path $pcm "mediaserver.log4cxx.xml") $pcmLog
    Write-Utf8File (Join-Path $pcm "mediaserver.cfg") ($mediaServerCfg.Replace("/opt/vrbt/bin/mediaserver_pcm/media", "$runtimeRoot/mediaserver_pcm/media"))
    Write-Utf8File (Join-Path $pcm "ipc_client.cfg") @"
[server_common]
connecting_timeout_ms = 100
reconnecting_delay_s = 30
receiving_timeout_s = 600
sending_timeout_s = 1200
enquire_link_sending_period_s = 15
max_recv_req_per_sec = 5000

[server1]
name=MEDIA_CTRL
ip=127.0.0.1
port=7200
session = MEDIA_CTRL,keep,$($node.session),$($node.session)
"@
    Write-Utf8File (Join-Path $root "local_rt\crbt-local-rt.env") @"
LOCAL_RT_BIND=$($inv.localRt.bind)
LOCAL_RT_PORT=$($inv.localRt.port)
LOCAL_RT_MEDIA_DIR=$runtimeRoot/mediaserver_pcm/media/local
LOCAL_RT_FALLBACK_SONG=$($inv.localRt.fallbackSong)
LOCAL_RT_DB_HOST=$($inv.localRt.dbHost)
LOCAL_RT_DB_PORT=$($inv.localRt.dbPort)
LOCAL_RT_DB_NAME=$($inv.localRt.dbName)
LOCAL_RT_DB_USER=$($inv.localRt.dbUser)
LOCAL_RT_DB_PASSWORD=$($inv.localRt.dbPassword)
LOCAL_RT_PROFILE_CACHE_SECONDS=$($inv.localRt.profileCacheSeconds)
LOCAL_RT_PROFILE_CACHE_MAX_ENTRIES=$($inv.localRt.profileCacheMaxEntries)
LOCAL_RT_MSISDN_PREFIX=$($inv.localRt.msisdnPrefix)
LOCAL_RT_CALLED_ROUTING_PREFIX=$($inv.localRt.calledRoutingPrefix)
"@
}

Copy-Item (Join-Path $PSScriptRoot "scripts") (Join-Path $OutputPath "scripts") -Recurse -Force
Copy-Item (Join-Path $PSScriptRoot "README.md") (Join-Path $OutputPath "README.md") -Force
Copy-Item $InventoryPath (Join-Path $OutputPath "inventory.json") -Force

if ($Zip) {
    $zipPath = "$OutputPath.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path (Join-Path $OutputPath "*") -DestinationPath $zipPath -CompressionLevel Optimal
    Write-Host "Created $zipPath"
}
Write-Host "Created Movitel bundle: $OutputPath"
