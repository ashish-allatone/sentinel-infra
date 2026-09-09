#requires -Version 5.1
<#
  setup-all.ps1 - brings the whole sentinel stack up inside a Docker-in-Docker
  container, driven entirely from PowerShell. No .sh file needed.

    .\setup-all.ps1
    .\setup-all.ps1 -Url https://your-host/code.zip

  Requires Docker Desktop in Linux-container mode. --privileged is effectively
  host root, so this is a dev/CI tool.
#>

[CmdletBinding()]
param(
    [string]$Url = ''
)

# IMPORTANT: must stay 'Continue'.
# Docker writes progress and warnings to stderr. PowerShell turns native-command
# stderr into error records, so with 'Stop' the script dies on the first such
# line (that is the NativeCommandError you saw on "docker rm -f"). Exit codes are
# checked explicitly below instead.
$ErrorActionPreference = 'Continue'

# ============================ CONFIG ============================
$Dind    = 'sentinel-dind'
$Image   = 'docker:27-dind'
$Volume  = 'sentinel_dind_lib'
$Network = 'sentinel-net'

$PgUser = $env:PG_USER;   if (-not $PgUser) { $PgUser = 'dbmasteruser' }
$PgPass = $env:PG_PASS;   if (-not $PgPass) { $PgPass = 'dbmasterpassword' }
$PgDb   = $env:PG_DB;     if (-not $PgDb)   { $PgDb   = 'productiondb' }

$MqttUser = $env:MQTT_USER; if (-not $MqttUser) { $MqttUser = 'mqttmasteruser' }
$MqttPass = $env:MQTT_PASS; if (-not $MqttPass) { $MqttPass = 'mqttmasterpassword' }

$GfUser = $env:GF_USER; if (-not $GfUser) { $GfUser = 'admin' }
$GfPass = $env:GF_PASS; if (-not $GfPass) { $GfPass = 'grafanamasterpassword' }

$PgPort     = 5432
$MqttPort   = 1883
$MqttWsPort = 9001
$GrafPort   = 3000
$AppPort    = 8000
# ===============================================================

function Log  ($m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Fail ($m) { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

# Copies a text blob into the DinD container with LF endings.
# Writing config via `sh -c` here-strings does not work reliably: a CRLF-saved
# .ps1 sends "EOF`r" as the heredoc terminator, which never matches "EOF", so
# the shell hangs or errors. docker cp sidesteps the problem entirely.
function Copy-TextInto {
    param([string]$Content, [string]$DestPath)

    $lf   = $Content -replace "`r`n", "`n"
    $tmp  = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($tmp, $lf, (New-Object System.Text.UTF8Encoding($false)))
    try {
        $parent = $DestPath.Substring(0, $DestPath.LastIndexOf('/'))
        docker exec $Dind mkdir -p $parent | Out-Null
        docker cp $tmp "${Dind}:${DestPath}" | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "Could not copy a file into $Dind ($DestPath)." }
    } finally {
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
    }
}

# Name-based existence test. The old `docker inspect` + $LASTEXITCODE pattern is
# fragile: any cmdlet in between leaves a stale exit code behind, and a missing
# container makes docker print to stderr.
function Remove-OuterContainer ($name) {
    $hit = docker ps -a --filter "name=^/$name$" --format '{{.Names}}' 2>$null
    if ($hit) { Warn "Removing existing $name"; docker rm -f $name 2>$null | Out-Null }
}

function Remove-InnerContainer ($name) {
    $hit = docker exec $Dind docker ps -a --filter "name=^/$name$" --format '{{.Names}}' 2>$null
    if ($hit) { docker exec $Dind docker rm -f $name 2>$null | Out-Null }
}

function Test-InnerRunning ($name) {
    $state = docker exec $Dind docker inspect -f '{{.State.Running}}' $name 2>$null
    return ($state -eq 'true')
}

# ------------------------- host Docker -------------------------
docker info *> $null
if ($LASTEXITCODE -ne 0) { Fail "Docker Desktop is not running." }

if ((docker info --format '{{.OSType}}') -ne 'linux') {
    Fail "Switch Docker Desktop to Linux containers."
}
Log "Docker ready"

# --------------------------- DinD ------------------------------
Remove-OuterContainer $Dind

Log "Pulling $Image ..."
docker pull $Image
if ($LASTEXITCODE -ne 0) { Fail "Could not pull $Image." }

docker volume create $Volume | Out-Null

docker run -d `
    --name $Dind `
    --restart unless-stopped `
    --privileged `
    -e "DOCKER_TLS_CERTDIR=" `
    -p "$($PgPort):5432" `
    -p "$($MqttPort):1883" `
    -p "$($MqttWsPort):9001" `
    -p "$($GrafPort):3000" `
    -p "$($AppPort):8000" `
    -v "${Volume}:/var/lib/docker" `
    $Image | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Could not start $Dind - are those host ports free?" }
Log "DinD started"

# --------------------- wait for inner daemon -------------------
Write-Host "[+] Waiting for inner Docker..."
$innerReady = $false
for ($i = 0; $i -lt 40; $i++) {
    docker exec $Dind docker info *> $null
    if ($LASTEXITCODE -eq 0) { $innerReady = $true; break }
    Start-Sleep -Seconds 3
}
if (-not $innerReady) {
    docker logs --tail 40 $Dind
    Fail "Inner Docker failed to start."
}
Log "Inner Docker ready"

# -------------------------- network ----------------------------
docker exec $Dind docker network inspect $Network *> $null
if ($LASTEXITCODE -ne 0) {
    docker exec $Dind docker network create $Network | Out-Null
}

# ------------------------- PostgreSQL --------------------------
Log "Pulling postgres:16 ..."
docker exec $Dind docker pull postgres:16 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Could not pull postgres:16 inside $Dind." }

Remove-InnerContainer 'sentineldb'
docker exec $Dind docker volume create sentinel_pgdata | Out-Null

docker exec $Dind docker run -d `
    --name sentineldb `
    --restart unless-stopped `
    --network $Network `
    -e "POSTGRES_USER=$PgUser" `
    -e "POSTGRES_PASSWORD=$PgPass" `
    -e "POSTGRES_DB=$PgDb" `
    -p "5432:5432" `
    -v "sentinel_pgdata:/var/lib/postgresql/data" `
    postgres:16 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Could not start sentineldb." }
Log "PostgreSQL started"

# -------------------------- Mosquitto --------------------------
Log "Pulling eclipse-mosquitto:2 ..."
docker exec $Dind docker pull eclipse-mosquitto:2 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Could not pull eclipse-mosquitto:2 inside $Dind." }

Remove-InnerContainer 'sentinel-mqtt'

$mosquittoConf = @'
persistence true
persistence_location /mosquitto/data/
log_dest stdout

listener 1883 0.0.0.0
protocol mqtt

listener 9001 0.0.0.0
protocol websockets

allow_anonymous false
password_file /mosquitto/config/passwordfile
'@
Copy-TextInto -Content $mosquittoConf -DestPath '/srv/sentinel/mosquitto/config/mosquitto.conf'

docker exec $Dind docker run --rm `
    --entrypoint mosquitto_passwd `
    -v "/srv/sentinel/mosquitto/config:/mosquitto/config" `
    eclipse-mosquitto:2 `
    -b -c /mosquitto/config/passwordfile $MqttUser $MqttPass
if ($LASTEXITCODE -ne 0) { Fail "Could not generate the MQTT password file." }
docker exec $Dind chmod 0644 /srv/sentinel/mosquitto/config/passwordfile | Out-Null

docker exec $Dind docker volume create sentinel_mqtt_data | Out-Null
docker exec $Dind docker volume create sentinel_mqtt_log  | Out-Null

docker exec $Dind docker run -d `
    --name sentinel-mqtt `
    --restart unless-stopped `
    --network $Network `
    -p "1883:1883" `
    -p "9001:9001" `
    -v "/srv/sentinel/mosquitto/config:/mosquitto/config" `
    -v "sentinel_mqtt_data:/mosquitto/data" `
    -v "sentinel_mqtt_log:/mosquitto/log" `
    eclipse-mosquitto:2 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Could not start sentinel-mqtt." }

Start-Sleep -Seconds 3
if (-not (Test-InnerRunning 'sentinel-mqtt')) {
    docker exec $Dind docker logs --tail 30 sentinel-mqtt
    Fail "Mosquitto exited immediately - see the log above."
}
Log "Mosquitto started"

# --------------------- wait for PostgreSQL ---------------------
Write-Host "[+] Waiting for PostgreSQL..."
$pgReady = $false
for ($i = 0; $i -lt 30; $i++) {
    docker exec $Dind docker exec sentineldb pg_isready -U $PgUser -d $PgDb *> $null
    if ($LASTEXITCODE -eq 0) { $pgReady = $true; break }
    Start-Sleep -Seconds 2
}
# The original loop discarded this result, so Grafana was provisioned against a
# database that may never have come up.
if (-not $pgReady) {
    docker exec $Dind docker logs --tail 30 sentineldb
    Fail "PostgreSQL did not become ready in ~60s."
}
Log "PostgreSQL ready"

# --------------------------- Grafana ---------------------------
$grafanaDs = @"
apiVersion: 1

datasources:
  - name: SentinelDB
    type: postgres
    access: proxy
    url: sentineldb:5432
    database: $PgDb
    user: $PgUser
    isDefault: true
    editable: true
    secureJsonData:
      password: $PgPass
    jsonData:
      sslmode: disable
      postgresVersion: 1600
"@
Copy-TextInto -Content $grafanaDs -DestPath '/srv/sentinel/grafana/provisioning/datasources/sentineldb.yaml'

Log "Pulling grafana/grafana-oss:11.1.0 ..."
docker exec $Dind docker pull grafana/grafana-oss:11.1.0 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Could not pull grafana inside $Dind." }

Remove-InnerContainer 'sentinel-grafana'
docker exec $Dind docker volume create sentinel_grafana_data | Out-Null

docker exec $Dind docker run -d `
    --name sentinel-grafana `
    --restart unless-stopped `
    --network $Network `
    -e "GF_SECURITY_ADMIN_USER=$GfUser" `
    -e "GF_SECURITY_ADMIN_PASSWORD=$GfPass" `
    -e "GF_USERS_ALLOW_SIGN_UP=false" `
    -p "3000:3000" `
    -v "sentinel_grafana_data:/var/lib/grafana" `
    -v "/srv/sentinel/grafana/provisioning/datasources:/etc/grafana/provisioning/datasources" `
    grafana/grafana-oss:11.1.0 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Could not start sentinel-grafana." }
Log "Grafana started"

# ------------------------- application -------------------------
if ($Url) {
    Log "Downloading application..."

    # Single-line sh commands: no heredocs, so nothing to break on CRLF.
    docker exec $Dind sh -c "command -v curl >/dev/null 2>&1 || apk add --no-cache curl >/dev/null"  | Out-Null
    docker exec $Dind sh -c "command -v unzip >/dev/null 2>&1 || apk add --no-cache unzip >/dev/null" | Out-Null

    docker exec $Dind sh -c "rm -rf /tmp/app && mkdir -p /tmp/app && curl -fsSL '$Url' -o /tmp/app/code.zip"
    if ($LASTEXITCODE -ne 0) { Fail "Download failed: $Url" }

    docker exec $Dind sh -c "cd /tmp/app && unzip -q code.zip && rm -f code.zip"
    if ($LASTEXITCODE -ne 0) { Fail "Could not unpack the archive." }

    # Most zips contain one top-level folder; the build context is that folder,
    # not /tmp/app. Building /tmp/app directly is why "Dockerfile not found" hits.
    $ctx = (docker exec $Dind sh -c 'n=$(find /tmp/app -mindepth 1 -maxdepth 1 ! -name __MACOSX | wc -l); d=$(find /tmp/app -mindepth 1 -maxdepth 1 -type d ! -name __MACOSX | head -n1); if [ "$n" -eq 1 ] && [ -n "$d" ]; then echo "$d"; else echo /tmp/app; fi').Trim()
    Log "Build context: $ctx"

    docker exec $Dind test -f "$ctx/Dockerfile" *> $null
    if ($LASTEXITCODE -ne 0) {
        Fail "No Dockerfile in the archive. Add one at the project root and re-run."
    }

    Log "Building sentinel-api ..."
    docker exec $Dind docker build -t sentinel-api $ctx
    if ($LASTEXITCODE -ne 0) { Fail "docker build failed - see the output above." }

    Remove-InnerContainer 'sentinel-api'

    docker exec $Dind test -f "$ctx/.env" *> $null
    $hasEnv = ($LASTEXITCODE -eq 0)

    if ($hasEnv) {
        Log "Using bundled .env"
        docker exec $Dind docker run -d `
            --name sentinel-api `
            --restart unless-stopped `
            --network $Network `
            -p "8000:8000" `
            --env-file "$ctx/.env" `
            sentinel-api | Out-Null
    } else {
        Warn "No .env in the archive - injecting default DB/MQTT settings"
        docker exec $Dind docker run -d `
            --name sentinel-api `
            --restart unless-stopped `
            --network $Network `
            -p "8000:8000" `
            -e "DATABASE_URL=postgresql+asyncpg://${PgUser}:${PgPass}@sentineldb:5432/${PgDb}" `
            -e "MQTT_HOST=sentinel-mqtt" `
            -e "MQTT_PORT=1883" `
            -e "MQTT_USERNAME=$MqttUser" `
            -e "MQTT_PASSWORD=$MqttPass" `
            sentinel-api | Out-Null
    }
    if ($LASTEXITCODE -ne 0) { Fail "Could not start sentinel-api." }

    Start-Sleep -Seconds 3
    if (Test-InnerRunning 'sentinel-api') {
        Log "API started"
    } else {
        docker exec $Dind docker logs --tail 40 sentinel-api
        Warn "API container exited - see the log above."
    }
}

# ---------------------------- done -----------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Sentinel stack is running" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "PostgreSQL : localhost:$PgPort   (user $PgUser, db $PgDb)"
Write-Host "MQTT       : localhost:$MqttPort   (user $MqttUser)"
Write-Host "MQTT WS    : localhost:$MqttWsPort"
Write-Host "Grafana    : http://localhost:$GrafPort   (user $GfUser)"
if ($Url) { Write-Host "API        : http://localhost:$AppPort" }
Write-Host ""
docker exec $Dind docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
Write-Host ""
Write-Host "Tear down:  docker rm -f $Dind; docker volume rm $Volume" -ForegroundColor DarkGray