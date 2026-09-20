#!/usr/bin/env bash
# setup-all.sh — postgres + mosquitto + grafana (+ optional app) on one docker network,
# running directly on the host Docker daemon.
#
#   ./setup-all.sh
#   ZIP_URL=https://host/code.zip ./setup-all.sh
#
# Credentials can be overridden from the environment, e.g.
#   PG_PASS='...' GF_PASS='...' ./setup-all.sh

# --- must be bash: ${BASH_SOURCE[0]} below is bash-only -----------------------
if [ -z "${BASH_VERSION:-}" ]; then
  echo "[x] Run this with bash, not sh:  bash $0" >&2
  exit 1
fi

set -euo pipefail

NET="${NET:-sentinel-net}"
PG_USER="${PG_USER:-dbmasteruser}"
PG_PASS="${PG_PASS:-dbmasterpassword}"
PG_DB="${PG_DB:-productiondb}"
MQ_USER="${MQ_USER:-mqttmasteruser}"
MQ_PASS="${MQ_PASS:-mqttmasterpassword}"
GF_USER="${GF_USER:-admin}"
GF_PASS="${GF_PASS:-grafanamasterpassword}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MQ_DIR="$DIR/mosquitto/config"
GF_DIR="$DIR/grafana/datasources"

APP_IMAGE="${APP_IMAGE:-sentinel-api}"
APP_PORT="${APP_PORT:-8000}"
APP_MODULE="${APP_MODULE:-main:app}"
ZIP_URL="${ZIP_URL:-}"

log()  { printf '\033[1;32m[+] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

# ------------------------------- docker --------------------------------------
command -v docker >/dev/null || die "docker not installed: curl -fsSL https://get.docker.com | sh"
docker info >/dev/null 2>&1 || die "docker daemon unreachable (try: sudo usermod -aG docker \$USER, then re-login)"
docker network create "$NET" >/dev/null 2>&1 || true

# ------------------------------ postgres -------------------------------------
log "pulling postgres:16 ..."
docker pull -q postgres:16 >/dev/null
docker rm -f sentineldb >/dev/null 2>&1 || true
docker run -d --name sentineldb --restart unless-stopped --network "$NET" \
  -e POSTGRES_USER="$PG_USER" -e POSTGRES_PASSWORD="$PG_PASS" -e POSTGRES_DB="$PG_DB" \
  -p 5432:5432 -v sentinel_pgdata:/var/lib/postgresql/data postgres:16 >/dev/null
log "postgres started"

# ------------------------------ mosquitto ------------------------------------
# Listeners below are container-internal; host ports come from -p.
mkdir -p "$MQ_DIR"
cat > "$MQ_DIR/mosquitto.conf" <<'EOF'
persistence true
persistence_location /mosquitto/data/
log_dest stdout
listener 1883 0.0.0.0
protocol mqtt
listener 9001 0.0.0.0
protocol websockets
allow_anonymous false
password_file /mosquitto/config/passwordfile
EOF

log "pulling eclipse-mosquitto:2 ..."
docker pull -q eclipse-mosquitto:2 >/dev/null
docker run --rm --entrypoint mosquitto_passwd -v "$MQ_DIR:/mosquitto/config" \
  eclipse-mosquitto:2 -b -c /mosquitto/config/passwordfile "$MQ_USER" "$MQ_PASS"
chmod 0644 "$MQ_DIR/passwordfile" 2>/dev/null || true
[ -s "$MQ_DIR/passwordfile" ] || die "MQTT password file not created"

docker rm -f sentinel-mqtt >/dev/null 2>&1 || true
docker run -d --name sentinel-mqtt --restart unless-stopped --network "$NET" \
  -p 1883:1883 -p 9001:9001 -v "$MQ_DIR:/mosquitto/config" \
  -v sentinel_mqtt_data:/mosquitto/data -v sentinel_mqtt_log:/mosquitto/log \
  eclipse-mosquitto:2 >/dev/null
sleep 3
if [ "$(docker inspect -f '{{.State.Running}}' sentinel-mqtt)" != true ]; then
  docker logs --tail 20 sentinel-mqtt
  die "mosquitto exited"
fi
log "mosquitto started"

# --------------------------- wait for postgres -------------------------------
pg_ok=0
for _ in $(seq 1 30); do
  if docker exec sentineldb pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
    pg_ok=1
    log "postgres ready"
    break
  fi
  sleep 2
done
# FIX: previously the loop could time out silently and Grafana would be
# provisioned against a database that never came up.
if [ "$pg_ok" -ne 1 ]; then
  docker logs --tail 30 sentineldb
  die "postgres did not become ready in ~60s"
fi

# ------------------------------- grafana -------------------------------------
mkdir -p "$GF_DIR"
cat > "$GF_DIR/sentineldb.yaml" <<EOF
apiVersion: 1
datasources:
  - name: SentinelDB
    type: postgres
    access: proxy
    url: sentineldb:5432
    database: $PG_DB
    user: $PG_USER
    isDefault: true
    editable: true
    secureJsonData:
      password: $PG_PASS
    jsonData:
      sslmode: disable
      postgresVersion: 1600
EOF

log "pulling grafana/grafana-oss:11.1.0 ..."
docker pull -q grafana/grafana-oss:11.1.0 >/dev/null
docker rm -f sentinel-grafana >/dev/null 2>&1 || true
docker run -d --name sentinel-grafana --restart unless-stopped --network "$NET" \
  -e GF_SECURITY_ADMIN_USER="$GF_USER" \
  -e GF_SECURITY_ADMIN_PASSWORD="$GF_PASS" \
  -e GF_USERS_ALLOW_SIGN_UP=false \
  -p 3000:3000 -v sentinel_grafana_data:/var/lib/grafana \
  -v "$GF_DIR:/etc/grafana/provisioning/datasources" \
  grafana/grafana-oss:11.1.0 >/dev/null
log "grafana started"

# --------------------------- app (only if ZIP_URL) ---------------------------
if [ -n "$ZIP_URL" ]; then
  command -v curl  >/dev/null || die "curl is required to fetch ZIP_URL"
  command -v unzip >/dev/null || die "unzip is required to unpack ZIP_URL"

  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT INT TERM

  log "downloading app ..."
  curl -fsSL "$ZIP_URL" -o "$WORK/c.zip"
  ( cd "$WORK" && unzip -q c.zip && rm -f c.zip )

  CTX="$WORK"
  n=$(find "$WORK" -mindepth 1 -maxdepth 1 ! -name __MACOSX | wc -l)
  d=$(find "$WORK" -mindepth 1 -maxdepth 1 -type d ! -name __MACOSX | head -n1)
  if [ "$n" -eq 1 ] && [ -n "$d" ]; then CTX="$d"; fi

  if [ -f "$CTX/Dockerfile" ]; then
    log "using the project's own Dockerfile"
  else
    # FIX: the old generated Dockerfile hardcoded COPY frontend/ src/ agent/ and
    # failed with an opaque COPY error whenever the archive lacked any of them.
    # Now each stage/line is emitted only if that directory actually exists.
    warn "no Dockerfile in the archive — generating one"
    [ -f "$CTX/requirements.txt" ] || die "no requirements.txt in the archive; add a Dockerfile instead"

    HAS_FRONTEND=0
    if [ -d "$CTX/frontend" ] && [ -f "$CTX/frontend/package.json" ]; then HAS_FRONTEND=1; fi

    APP_SRC_DIR=""
    for cand in src app .; do
      if [ -d "$CTX/$cand" ]; then APP_SRC_DIR="$cand"; break; fi
    done

    : > "$CTX/Dockerfile"
    if [ "$HAS_FRONTEND" -eq 1 ]; then
      cat >> "$CTX/Dockerfile" <<'EOF'
FROM node:20-alpine AS frontend-build
WORKDIR /app/frontend
COPY frontend/package*.json ./
RUN npm install
COPY frontend/ ./
RUN npm run build

EOF
    else
      warn "no frontend/ directory — skipping the node build stage"
    fi

    cat >> "$CTX/Dockerfile" <<'EOF'
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends gcc \
    && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && pip install --no-cache-dir -r requirements.txt
EOF

    if [ "$APP_SRC_DIR" = "." ]; then
      echo 'COPY . .' >> "$CTX/Dockerfile"
      WORKDIR_IN_IMAGE="/app"
    else
      echo "COPY ${APP_SRC_DIR}/ ./${APP_SRC_DIR}" >> "$CTX/Dockerfile"
      WORKDIR_IN_IMAGE="/app/${APP_SRC_DIR}"
    fi
    [ -d "$CTX/agent" ] && echo 'COPY agent/ ./agent' >> "$CTX/Dockerfile"
    [ "$HAS_FRONTEND" -eq 1 ] && \
      echo 'COPY --from=frontend-build /app/frontend/build ./frontend/build' >> "$CTX/Dockerfile"

    cat >> "$CTX/Dockerfile" <<EOF
WORKDIR ${WORKDIR_IN_IMAGE}
EXPOSE ${APP_PORT}
CMD ["uvicorn", "${APP_MODULE}", "--host", "0.0.0.0", "--port", "${APP_PORT}"]
EOF
  fi

  log "building ${APP_IMAGE} ..."
  docker build -t "$APP_IMAGE" "$CTX"

  if [ -f "$CTX/.env" ]; then
    log "using bundled .env"
    ENV_ARGS=(--env-file "$CTX/.env")
  else
    warn "no .env in the archive — injecting default DB/MQTT settings"
    ENV_ARGS=(-e "DATABASE_URL=postgresql+asyncpg://${PG_USER}:${PG_PASS}@sentineldb:5432/${PG_DB}"
              -e MQTT_HOST=sentinel-mqtt -e MQTT_PORT=1883
              -e MQTT_USERNAME="$MQ_USER" -e MQTT_PASSWORD="$MQ_PASS")
  fi

  docker rm -f sentinel-api >/dev/null 2>&1 || true
  docker run -d --name sentinel-api --restart unless-stopped --network "$NET" \
    -p "${APP_PORT}:${APP_PORT}" ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} "$APP_IMAGE" >/dev/null
  sleep 3
  if [ "$(docker inspect -f '{{.State.Running}}' sentinel-api)" = true ]; then
    log "app started"
  else
    docker logs --tail 30 sentinel-api
    warn "app container exited — see the logs above"
  fi
fi

# -------------------------------- summary ------------------------------------
cat <<EOF

postgres  localhost:5432   user=$PG_USER  db=$PG_DB
mqtt      localhost:1883   ws:9001   user=$MQ_USER
grafana   http://localhost:3000   user=$GF_USER
EOF
[ -n "$ZIP_URL" ] && printf 'app       http://localhost:%s\n' "$APP_PORT"
cat <<'EOF'
in-app hosts: sentineldb:5432, sentinel-mqtt:1883
(passwords are the values in this script / your environment)
EOF