param(
    [string]$OutputPath = (Join-Path $PSScriptRoot "dist"),
    [switch]$Zip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repo "swapfile_ringtone"

if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Recurse -Force }
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $OutputPath "payload") | Out-Null
$runtimeRoot = "/u01/crbt-movitel"
$payload = Join-Path $OutputPath "payload\swapfile_ringtone"
New-Item -ItemType Directory -Force -Path $payload | Out-Null
Get-ChildItem -LiteralPath $source -Force | Where-Object { $_.Name -ne "nohup.out" } |
    Copy-Item -Destination $payload -Recurse -Force

# Do not bundle an old stdout capture from a previous manual start.
Remove-Item -LiteralPath (Join-Path $payload "bin\nohup.out") -Force -ErrorAction SilentlyContinue
$commonCfg = Join-Path $payload "config\common.cfg"
$logCfg = Join-Path $payload "config\log4j.swapfile.xml"
$controller = Join-Path $payload "bin\controller.sh"
[System.IO.File]::WriteAllText($commonCfg, (Get-Content $commonCfg -Raw).Replace("/opt/vrbt/ramdisk", "$runtimeRoot/ramdisk"), (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($logCfg, (Get-Content $logCfg -Raw).Replace("/opt/vrbt/log", "$runtimeRoot/log"), (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($controller, (Get-Content $controller -Raw).Replace("/opt/vrbt/log", "$runtimeRoot/log"), (New-Object System.Text.UTF8Encoding($false)))
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "scripts") -Destination (Join-Path $OutputPath "scripts") -Recurse -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "swapfile-ringtone.service") -Destination $OutputPath -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "README.md") -Destination $OutputPath -Force

if ($Zip) {
    $zipPath = "$OutputPath.zip"
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Compress-Archive -Path (Join-Path $OutputPath "*") -DestinationPath $zipPath -CompressionLevel Optimal
    Write-Host "Created $zipPath"
}
Write-Host "Created swapfile bundle: $OutputPath"
