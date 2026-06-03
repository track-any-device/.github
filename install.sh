#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Track Any Device — Platform Install / Update Script
#
# Usage — fresh install:
#   curl -fsSL https://raw.githubusercontent.com/track-any-device/.github/main/install.sh | bash
#
# Usage — update running stack to latest pinned versions:
#   bash install.sh --update
#
# Options:
#   --update    Pull new images and restart changed services (skip .env creation)
#   --dir PATH  Override install directory (default: ~/tad or $TAD_DIR)
#   --dry-run   Print what would happen without making any changes
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Version matrix ────────────────────────────────────────────────────────────
# Auto-updated by each server app's release CI workflow.
# Do not edit manually — use the release workflow or bump via GitHub Actions.
#
# VERSIONS_START
TAD_SERVER_LOGIN_TAG="v0.4.3"                # bumped by server-login CI
TAD_SERVER_ADMIN_TAG="v0.0.9"               # bumped by server-admin CI
TAD_SERVER_API_TAG="v0.1.424-ac19c5e0"      # bumped by app CI (api/cron/queue/cli)
TAD_SERVER_GRAPHQL_TAG="v0.0.7"             # bumped by server-graphql CI
TAD_SERVER_TENANT_TAG="latest"              # bumped by server-tenant CI
TAD_SERVER_WEB_TAG="latest"                 # bumped by web CI
TAD_JT808_TAG="0.1.1"                       # bumped by server-jt808 CI
TAD_P901_TAG="0.1.1"                        # bumped by server-jt808 CI (simulator)
# VERSIONS_END

# Third-party image pins — upgrade intentionally after testing.
MYSQL_VERSION="8.0.32"
REDIS_VERSION="7-alpine"
SOKETI_VERSION="1.4-16-alpine"
INFLUXDB_VERSION="2.7-alpine"
MAILPIT_VERSION="v1.24.0"
PMA_VERSION="5.2.2"
CLOUDFLARED_VERSION="2025.5.0"
GRAFANA_VERSION="11.6.0"
LOKI_VERSION="3.5.0"
FRPC_VERSION="0.61.1"

# ── Config ────────────────────────────────────────────────────────────────────
INSTALL_DIR="${TAD_DIR:-$HOME/tad}"
ORG="trackanydevice"
SCRIPT_VERSION="$(grep -m1 'TAD_SERVER_API_TAG' "$0" | grep -oP '(?<=\").*(?=\")')"
DRY_RUN=false
UPDATE_ONLY=false

# ── Colours ───────────────────────────────────────────────────────────────────
BOLD="\033[1m"; RESET="\033[0m"
GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; CYAN="\033[36m"

log()  { echo -e "${BOLD}${CYAN}[TAD]${RESET} $*"; }
ok()   { echo -e "${BOLD}${GREEN}  ✓${RESET}  $*"; }
warn() { echo -e "${BOLD}${YELLOW}  !${RESET}  $*"; }
err()  { echo -e "${BOLD}${RED}  ✗${RESET}  $*" >&2; }
run()  { if $DRY_RUN; then echo -e "  ${YELLOW}[dry]${RESET} $*"; else eval "$*"; fi; }

# ── Parse arguments ───────────────────────────────────────────────────────────
for arg in "$@"; do
  case $arg in
    --update)   UPDATE_ONLY=true ;;
    --dry-run)  DRY_RUN=true ;;
    --dir=*)    INSTALL_DIR="${arg#*=}" ;;
    --dir)      shift; INSTALL_DIR="$1" ;;
  esac
done

# ── Prerequisites ─────────────────────────────────────────────────────────────
check_prerequisites() {
  log "Checking prerequisites..."
  local missing=()

  command -v docker  &>/dev/null || missing+=("docker")
  command -v curl    &>/dev/null || missing+=("curl")
  command -v python3 &>/dev/null || missing+=("python3")

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required tools: ${missing[*]}"
    echo "  Install Docker: https://docs.docker.com/get-docker/"
    exit 1
  fi

  # docker compose v2 check
  if ! docker compose version &>/dev/null; then
    err "Docker Compose v2 is required (docker compose, not docker-compose)."
    echo "  Install: https://docs.docker.com/compose/install/"
    exit 1
  fi

  ok "Docker $(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)"
  ok "Docker Compose $(docker compose version --short)"
}

# ── Directory structure ───────────────────────────────────────────────────────
create_directories() {
  log "Creating directory structure at ${INSTALL_DIR}..."

  run "mkdir -p '${INSTALL_DIR}'"
  run "mkdir -p '${INSTALL_DIR}/storage/app/public'"
  run "mkdir -p '${INSTALL_DIR}/storage/logs'"
  run "mkdir -p '${INSTALL_DIR}/storage/oauth-keys'"
  run "mkdir -p '${INSTALL_DIR}/docker/loki'"
  run "mkdir -p '${INSTALL_DIR}/docker/grafana/provisioning'"
  run "mkdir -p '${INSTALL_DIR}/docker/promtail'"
  run "mkdir -p '${INSTALL_DIR}/docker/frpc'"

  # Permissions — storage writable by container user (uid 82 / www-data)
  if ! $DRY_RUN; then
    chmod -R 775 "${INSTALL_DIR}/storage" 2>/dev/null || true
  fi

  ok "Directories ready"
}

# ── Environment file ──────────────────────────────────────────────────────────
create_env() {
  local env_file="${INSTALL_DIR}/.env"
  local example_url="https://raw.githubusercontent.com/track-any-device/.github/main/.env.example"

  if [[ -f "$env_file" ]]; then
    warn ".env already exists — skipping (edit manually to change settings)"
    return
  fi

  log "Creating .env from template..."
  if ! $DRY_RUN; then
    if curl -fsSL "$example_url" -o "${env_file}.example" 2>/dev/null; then
      cp "${env_file}.example" "$env_file"
      ok ".env created at ${env_file}"
      warn "IMPORTANT: Edit ${env_file} and fill in required values before starting."
      warn "  Required: MYSQL_ROOT_PASSWORD, MYSQL_PASSWORD, APP keys, Pusher config,"
      warn "            Cloudflare Tunnel token, Passport keys."
      warn "  Pre-seeded (no config needed): Web SSO client, Mobile SSO client."
      warn "  Run 'php artisan db:seed' after first start to create these clients."
    else
      warn "Could not download .env.example — creating minimal template."
      generate_minimal_env "$env_file"
    fi
  else
    echo "  [dry] Would create ${env_file}"
  fi
}

generate_minimal_env() {
  local file="$1"
  cat > "$file" <<'ENV'
# Track Any Device — Platform Environment
# Fill in all required values before running install.sh --update or docker compose up

# ── Required ──────────────────────────────────────────────────────────────────
APP_DOMAIN=track-any-device.com
LOGIN_DOMAIN=login.track-any-device.com
ADMIN_DOMAIN=admin.track-any-device.com
GRAPHQL_DOMAIN=graphql.track-any-device.com

# Generate: openssl rand -base64 32
LOGIN_APP_KEY=base64:REPLACE_ME
ADMIN_APP_KEY=base64:REPLACE_ME
API_APP_KEY=base64:REPLACE_ME
GRAPHQL_APP_KEY=base64:REPLACE_ME

# MySQL
MYSQL_ROOT_PASSWORD=REPLACE_ME
MYSQL_DATABASE=tad
MYSQL_USER=tad
MYSQL_PASSWORD=REPLACE_ME

# Pusher / Soketi
PUSHER_APP_ID=tad-app
PUSHER_APP_KEY=REPLACE_ME
PUSHER_APP_SECRET=REPLACE_ME

# InfluxDB time-series telemetry
INFLUXDB_USER=admin
INFLUXDB_PASSWORD=REPLACE_ME
INFLUXDB_ORG=track-any-device
INFLUXDB_BUCKET=device_locations
INFLUXDB_TOKEN=REPLACE_ME

# Cloudflare Tunnel (Zero Trust → Networks → Tunnels → Create tunnel)
CLOUDFLARE_TUNNEL_TOKEN=REPLACE_ME

# Passport OAuth2 keys — generate once:
#   docker run --rm php:8.5-alpine sh -c \
#     "apk add -q openssl && openssl genrsa 4096 | base64 -w0 && echo && \
#      openssl rsa -pubout 2>/dev/null | base64 -w0"
PASSPORT_PRIVATE_KEY_B64=REPLACE_ME
PASSPORT_PUBLIC_KEY_B64=REPLACE_ME

# ── Pre-seeded OAuth clients (no configuration required) ─────────────────────
# The following clients are seeded automatically by 'php artisan db:seed'.
# They use static well-known credentials so web and mobile work out of the box.
# For production: delete the rows from oauth_clients and override via env vars.
#
#   Web portal  — client_id: tad_web_portal    secret: tad_web_portal_secret
#   Mobile app  — client_id: tad_mobile_tad101 secret: (none — PKCE public client)
#   Admin panel — client_id: tad_admin_panel   secret: tad_admin_panel_secret
#   GraphQL     — client_id: tad_graphql_api   secret: tad_graphql_api_secret
#
# To rotate production secrets, set these env vars then re-seed:
# WEB_SSO_CLIENT_ID=your-custom-id
# WEB_SSO_CLIENT_SECRET=your-rotated-secret

# ── Optional ──────────────────────────────────────────────────────────────────
# SMS Gateway
SMS_GATEWAY_URL=
SMS_GATEWAY_API_KEY=
SMS_MASTER_NUMBER=

# GraphQL M2M (for server-to-server calls, not the explorer)
GRAPHQL_KEY=
GRAPHQL_SECRET=

# JT808 device type ID (from DeviceTypeSeeder)
JT808_DEVICE_TYPE_ID=1

# frp tunnel (profile: frp)
FRP_SERVER_ADDR=
FRP_TOKEN=change-me
ENV
}

# ── Docker Compose generation ─────────────────────────────────────────────────
generate_compose() {
  local file="${INSTALL_DIR}/docker-compose.yml"
  log "Generating docker-compose.yml (API: ${TAD_SERVER_API_TAG})..."

  if $DRY_RUN; then
    echo "  [dry] Would write ${file}"
    return
  fi

  cat > "$file" <<COMPOSE
# Auto-generated by install.sh — do not edit manually.
# Re-run 'bash install.sh --update' to regenerate with new versions.
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
#
# Versions:
#   server-login:    ${TAD_SERVER_LOGIN_TAG}
#   server-admin:    ${TAD_SERVER_ADMIN_TAG}
#   server-api:      ${TAD_SERVER_API_TAG}
#   server-graphql:  ${TAD_SERVER_GRAPHQL_TAG}
#   server-tenant:   ${TAD_SERVER_TENANT_TAG}
#   server-web:      ${TAD_SERVER_WEB_TAG}
#   jt808-server:    ${TAD_JT808_TAG}

x-app-base: &app-base
  networks: [tda]
  depends_on:
    mysql:  {condition: service_healthy}
    redis:  {condition: service_started}
    soketi: {condition: service_healthy}
  restart: unless-stopped

x-app-env: &app-env
  APP_ENV:   \${APP_ENV:-production}
  APP_DEBUG: \${APP_DEBUG:-false}
  TRUSTED_PROXIES: "*"
  SESSION_DOMAIN:  \${SESSION_DOMAIN:-.track-any-device.com}
  APP_DOMAIN:      \${APP_DOMAIN}
  LOGIN_DOMAIN:    \${LOGIN_DOMAIN}
  ADMIN_DOMAIN:    \${ADMIN_DOMAIN}
  GRAPHQL_DOMAIN:  \${GRAPHQL_DOMAIN}
  DB_CONNECTION: mysql
  DB_HOST: mysql
  DB_PORT: 3306
  DB_DATABASE:  \${MYSQL_DATABASE}
  DB_USERNAME:  \${MYSQL_USER}
  DB_PASSWORD:  \${MYSQL_PASSWORD}
  CACHE_STORE:      redis
  QUEUE_CONNECTION: redis
  SESSION_DRIVER:   redis
  REDIS_HOST: redis
  REDIS_PORT: 6379
  BROADCAST_CONNECTION: pusher
  PUSHER_APP_ID:     \${PUSHER_APP_ID}
  PUSHER_APP_KEY:    \${PUSHER_APP_KEY}
  PUSHER_APP_SECRET: \${PUSHER_APP_SECRET}
  PUSHER_HOST:   soketi
  PUSHER_PORT:   6001
  PUSHER_SCHEME: http
  PUSHER_APP_CLUSTER: mt1
  MAIL_MAILER: smtp
  MAIL_HOST:   mailtrap
  MAIL_PORT:   1025
  MAIL_FROM_ADDRESS: noreply@track-any-device.com
  INFLUXDB_HOST:   influxdb
  INFLUXDB_PORT:   8086
  INFLUXDB_BUCKET: \${INFLUXDB_BUCKET:-device_locations}
  INFLUXDB_ORG:    \${INFLUXDB_ORG:-track-any-device}
  INFLUXDB_TOKEN:  \${INFLUXDB_TOKEN}
  PASSPORT_PRIVATE_KEY_B64: \${PASSPORT_PRIVATE_KEY_B64}
  PASSPORT_PUBLIC_KEY_B64:  \${PASSPORT_PUBLIC_KEY_B64}

services:

  login:
    <<: *app-base
    image: ${ORG}/server-login:${TAD_SERVER_LOGIN_TAG}
    container_name: login
    volumes: [app_storage:/app/storage/app]
    environment:
      <<: *app-env
      APP_URL: https://\${LOGIN_DOMAIN}
      APP_KEY: \${LOGIN_APP_KEY}
      SESSION_COOKIE: login_session
      SMS_MASTER_NUMBER:   \${SMS_MASTER_NUMBER:-}
      SMS_GATEWAY_URL:     \${SMS_GATEWAY_URL:-}
      SMS_GATEWAY_API_KEY: \${SMS_GATEWAY_API_KEY:-}

  admin:
    <<: *app-base
    image: ${ORG}/server-admin:${TAD_SERVER_ADMIN_TAG}
    container_name: admin
    volumes: [app_storage:/app/storage/app]
    environment:
      <<: *app-env
      APP_URL: https://\${ADMIN_DOMAIN}
      APP_KEY: \${ADMIN_APP_KEY}
      SESSION_COOKIE: admin_session

  api:
    <<: *app-base
    image: ${ORG}/server-api:${TAD_SERVER_API_TAG}
    container_name: api
    environment:
      <<: *app-env
      APP_URL: https://api.\${APP_DOMAIN}
      APP_KEY: \${API_APP_KEY}

  graphql:
    <<: *app-base
    image: ${ORG}/server-graphql:${TAD_SERVER_GRAPHQL_TAG}
    container_name: graphql
    environment:
      <<: *app-env
      APP_URL: https://\${GRAPHQL_DOMAIN}
      APP_KEY: \${GRAPHQL_APP_KEY}
      SESSION_COOKIE: graphql_session
      GRAPHQL_KEY:    \${GRAPHQL_KEY:-}
      GRAPHQL_SECRET: \${GRAPHQL_SECRET:-}

  web:
    image: ${ORG}/server-web:${TAD_SERVER_WEB_TAG}
    container_name: web
    networks: [tda]
    restart: unless-stopped
    environment:
      NEXT_PUBLIC_APP_URL: https://\${APP_DOMAIN}
      GRAPHQL_URL:  http://graphql/graphql
      GRAPHQL_KEY:  \${GRAPHQL_KEY:-}
      GRAPHQL_SECRET: \${GRAPHQL_SECRET:-}
      API_URL: http://api
      SSO_CLIENT_ID:     \${WEB_SSO_CLIENT_ID:-}
      SSO_CLIENT_SECRET: \${WEB_SSO_CLIENT_SECRET:-}
      SSO_REDIRECT_URI:  https://\${APP_DOMAIN}/sso/callback
      SSO_AUTH_URL:      https://\${LOGIN_DOMAIN}/oauth/authorize
      SSO_TOKEN_URL:     https://\${LOGIN_DOMAIN}/oauth/token
      SSO_USERINFO_URL:  https://\${LOGIN_DOMAIN}/oauth/userinfo

  cron:
    <<: *app-base
    image: ${ORG}/server-cron:${TAD_SERVER_API_TAG}
    container_name: cron
    environment:
      <<: *app-env
      APP_KEY: \${API_APP_KEY}

  queue:
    <<: *app-base
    image: ${ORG}/server-queue:${TAD_SERVER_API_TAG}
    container_name: queue
    environment:
      <<: *app-env
      APP_KEY: \${API_APP_KEY}

  cli:
    image: ${ORG}/server-cli:${TAD_SERVER_API_TAG}
    container_name: cli
    networks: [tda]
    restart: unless-stopped
    depends_on:
      mysql: {condition: service_healthy}
      redis: {condition: service_started}
    environment:
      <<: *app-env
      APP_KEY: \${API_APP_KEY}

  jt808:
    image: ${ORG}/jt808-server:${TAD_JT808_TAG}
    container_name: jt808
    ports: ["7018:7018", "9090:9090"]
    networks: [tda]
    restart: unless-stopped
    depends_on:
      mysql: {condition: service_healthy}
      redis: {condition: service_started}
    environment:
      JT808_TCP_ADDR: :7018
      JT808_HTTP_ADDR: :9090
      REDIS_HOST: redis
      REDIS_PORT: 6379
      STREAM_KEY: jt808:telemetry
      STREAM_MAX_LEN: "100000"
      SESSION_PREFIX: "jt808:session:"
      AUTH_TOKEN_PREFIX: "jt808:authtoken:"
      ONLINE_Z_KEY: jt808:online
      CMD_CHANNEL: "jt808:cmd:"
      AUTH_TIMEOUT: 30s
      HEARTBEAT_TIMEOUT: 3m
      DB_HOST: mysql
      DB_PORT: 3306
      DB_DATABASE: \${MYSQL_DATABASE}
      DB_USERNAME: \${MYSQL_USER}
      DB_PASSWORD: \${MYSQL_PASSWORD}
      DB_DEVICE_TYPE_ID: \${JT808_DEVICE_TYPE_ID:-1}
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:9090/healthz || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s

  mysql:
    image: mysql:${MYSQL_VERSION}
    container_name: mysql
    init: true
    networks: [tda]
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE:      \${MYSQL_DATABASE}
      MYSQL_USER:          \${MYSQL_USER}
      MYSQL_PASSWORD:      \${MYSQL_PASSWORD}
    ports: ["3306:3306"]
    volumes: [mysql_data:/var/lib/mysql]
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p\${MYSQL_ROOT_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 10

  redis:
    image: redis:${REDIS_VERSION}
    container_name: redis
    networks: [tda]
    restart: unless-stopped
    ports: ["6379:6379"]

  soketi:
    image: quay.io/soketi/soketi:${SOKETI_VERSION}
    container_name: soketi
    networks: [tda]
    restart: unless-stopped
    ports: ["6001:6001", "9601:9601"]
    environment:
      SOKETI_DEFAULT_APP_ID:     \${PUSHER_APP_ID}
      SOKETI_DEFAULT_APP_KEY:    \${PUSHER_APP_KEY}
      SOKETI_DEFAULT_APP_SECRET: \${PUSHER_APP_SECRET}
      SOKETI_DEFAULT_APP_ENABLE_CLIENT_MESSAGES: "true"
      SOKETI_DEFAULT_APP_ENABLED: "true"
      SOKETI_DEFAULT_APP_MAX_CONNECTIONS: "\${SOKETI_MAX_CONNECTIONS:-500}"
      SOKETI_CORS_ALLOWED_ORIGINS: "*"
      SOKETI_DEFAULT_APP_WEBHOOKS: '[{"url":"http://api/api/v1/webhooks/soketi","event_types":["channel_occupied","channel_vacated"]}]'
    healthcheck:
      test: ["CMD-SHELL", "node -e \"const net=require('net');const s=net.connect(6001,'127.0.0.1');s.on('connect',()=>{s.end();process.exit(0);});s.on('error',()=>process.exit(1));\""]
      interval: 5s
      timeout: 2s
      retries: 10

  influxdb:
    image: influxdb:${INFLUXDB_VERSION}
    container_name: influxdb
    networks: [tda]
    restart: unless-stopped
    ports: ["8086:8086"]
    volumes: [influxdb_data:/var/lib/influxdb2]
    environment:
      DOCKER_INFLUXDB_INIT_MODE:        setup
      DOCKER_INFLUXDB_INIT_USERNAME:    \${INFLUXDB_USER:-admin}
      DOCKER_INFLUXDB_INIT_PASSWORD:    \${INFLUXDB_PASSWORD}
      DOCKER_INFLUXDB_INIT_ORG:         \${INFLUXDB_ORG:-track-any-device}
      DOCKER_INFLUXDB_INIT_BUCKET:      \${INFLUXDB_BUCKET:-device_locations}
      DOCKER_INFLUXDB_INIT_ADMIN_TOKEN: \${INFLUXDB_TOKEN}

  mailtrap:
    image: axllent/mailpit:${MAILPIT_VERSION}
    container_name: mailtrap
    networks: [tda]
    restart: unless-stopped
    ports: ["1025:1025", "8025:8025"]

  pma:
    image: phpmyadmin/phpmyadmin:${PMA_VERSION}
    container_name: pma
    networks: [tda]
    restart: unless-stopped
    ports: ["3333:80"]
    depends_on:
      mysql: {condition: service_healthy}
    environment:
      PMA_HOST:     mysql
      PMA_USER:     \${MYSQL_USER}
      PMA_PASSWORD: \${MYSQL_PASSWORD}

  cloudflared:
    image: cloudflare/cloudflared:${CLOUDFLARED_VERSION}
    container_name: cloudflared
    networks: [tda]
    restart: unless-stopped
    command: tunnel --no-autoupdate run --token \${CLOUDFLARE_TUNNEL_TOKEN}
    environment:
      TUNNEL_TOKEN: \${CLOUDFLARE_TUNNEL_TOKEN}
    dns: [8.8.8.8, 1.1.1.1]

  # ── Logging stack (docker compose --profile logging up -d) ──────────────────
  loki:
    image: grafana/loki:${LOKI_VERSION}
    container_name: loki
    networks: [tda]
    restart: unless-stopped
    command: -config.file=/etc/loki/loki-config.yml
    volumes: [loki_data:/loki]
    ports: ["3100:3100"]
    profiles: [logging]

  grafana:
    image: grafana/grafana:${GRAFANA_VERSION}
    container_name: grafana
    networks: [tda]
    restart: unless-stopped
    ports: ["3000:3000"]
    volumes: [grafana_data:/var/lib/grafana]
    profiles: [logging]
    environment:
      GF_AUTH_ANONYMOUS_ENABLED:  "true"
      GF_AUTH_ANONYMOUS_ORG_ROLE: Admin

  # ── frp tunnel (docker compose --profile frp up -d) ─────────────────────────
  frpc:
    image: snowdreamtech/frpc:${FRPC_VERSION}
    container_name: frpc
    networks: [tda]
    restart: unless-stopped
    profiles: [frp]
    depends_on:
      jt808: {condition: service_healthy}
    environment:
      FRP_SERVER_ADDR: \${FRP_SERVER_ADDR:-}
      FRP_TOKEN: \${FRP_TOKEN:-change-me}

  # ── GPS simulators (docker compose --profile sim up -d) ─────────────────────
  p901-0:
    image: ${ORG}/p901-device:${TAD_P901_TAG}
    container_name: p901-0
    networks: [tda]
    restart: unless-stopped
    profiles: [sim]
    depends_on:
      jt808: {condition: service_healthy}
    environment:
      DEVICE_IMEI: "00000000000000"
      SERVER_ADDR: "jt808:7018"
      INITIAL_LAT: "31.5204"
      INITIAL_LON: "74.3587"

  p901-1:
    image: ${ORG}/p901-device:${TAD_P901_TAG}
    container_name: p901-1
    networks: [tda]
    restart: unless-stopped
    profiles: [sim]
    depends_on:
      jt808: {condition: service_healthy}
    environment:
      DEVICE_IMEI: "11111111111111"
      SERVER_ADDR: "jt808:7018"
      INITIAL_LAT: "31.5304"
      INITIAL_LON: "74.3687"

networks:
  tda:
    driver: bridge

volumes:
  mysql_data:
  influxdb_data:
  loki_data:
  grafana_data:
  app_storage:
COMPOSE

  ok "docker-compose.yml generated at ${file}"
}

# ── Docker stack operations ───────────────────────────────────────────────────
stack_up() {
  local compose="${INSTALL_DIR}/docker-compose.yml"
  log "Pulling images..."
  run "docker compose -f '${compose}' pull --quiet"

  if docker compose -f "${compose}" ps -q 2>/dev/null | grep -q .; then
    log "Stack is running — updating changed services..."
    run "docker compose -f '${compose}' up -d --remove-orphans"
    ok "Stack updated"
  else
    log "Starting stack..."
    run "docker compose -f '${compose}' up -d"
    ok "Stack started"
  fi
}

wait_for_db() {
  local compose="${INSTALL_DIR}/docker-compose.yml"
  log "Waiting for MySQL to be ready..."
  local attempts=0
  while ! docker compose -f "${compose}" exec -T mysql \
      mysqladmin ping -u root -p"${MYSQL_ROOT_PASSWORD:-}" --silent &>/dev/null; do
    attempts=$((attempts + 1))
    if [[ $attempts -ge 30 ]]; then
      err "MySQL did not become ready within 5 minutes."
      exit 1
    fi
    echo -n "."
    sleep 10
  done
  echo ""
  ok "MySQL ready"
}

run_migrations() {
  local compose="${INSTALL_DIR}/docker-compose.yml"
  log "Running database migrations and seeders..."
  run "docker compose -f '${compose}' exec -T cli php artisan migrate --force --seed"
  ok "Database seeded"
}

# ── Status summary ────────────────────────────────────────────────────────────
show_status() {
  local compose="${INSTALL_DIR}/docker-compose.yml"
  echo ""
  echo -e "${BOLD}── Platform Status ─────────────────────────────────────────────${RESET}"
  if ! $DRY_RUN; then
    docker compose -f "${compose}" ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
  fi
  echo ""
  echo -e "${BOLD}── Version Matrix ──────────────────────────────────────────────${RESET}"
  echo "  server-login:   ${TAD_SERVER_LOGIN_TAG}"
  echo "  server-admin:   ${TAD_SERVER_ADMIN_TAG}"
  echo "  server-api:     ${TAD_SERVER_API_TAG}"
  echo "  server-graphql: ${TAD_SERVER_GRAPHQL_TAG}"
  echo "  server-tenant:  ${TAD_SERVER_TENANT_TAG}"
  echo "  server-web:     ${TAD_SERVER_WEB_TAG}"
  echo "  jt808-server:   ${TAD_JT808_TAG}"
  echo ""
  echo -e "${BOLD}── Access Points ───────────────────────────────────────────────${RESET}"
  echo "  Admin panel:  https://\${ADMIN_DOMAIN:-admin.track-any-device.com}"
  echo "  API:          https://api.\${APP_DOMAIN:-track-any-device.com}"
  echo "  phpMyAdmin:   http://localhost:3333"
  echo "  MailPit:      http://localhost:8025"
  echo "  JT808 TCP:    :7018"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗"
  echo -e "║   Track Any Device — Platform Installer                      ║"
  echo -e "║   API version: ${TAD_SERVER_API_TAG}$(printf '%*s' $((38 - ${#TAD_SERVER_API_TAG})) '')║"
  echo -e "╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""

  check_prerequisites

  if $UPDATE_ONLY; then
    log "Update mode — regenerating compose and pulling new images..."
    generate_compose
    stack_up
    show_status
    ok "Update complete."
  else
    log "Fresh install to: ${INSTALL_DIR}"
    create_directories
    create_env

    # Abort if .env still has REPLACE_ME placeholders
    if ! $DRY_RUN && grep -q "REPLACE_ME" "${INSTALL_DIR}/.env" 2>/dev/null; then
      echo ""
      warn "Your .env contains unfilled REPLACE_ME placeholders."
      warn "Edit ${INSTALL_DIR}/.env, then re-run: bash install.sh --update"
      exit 0
    fi

    generate_compose
    stack_up

    # Source .env to get MYSQL_ROOT_PASSWORD for wait_for_db
    set -a; source "${INSTALL_DIR}/.env" 2>/dev/null || true; set +a

    wait_for_db
    run_migrations
    show_status
    ok "Installation complete."
    echo ""
    echo -e "  Next steps:"
    echo -e "    1. Configure Cloudflare Tunnel public hostnames"
    echo -e "    2. Log in to admin panel and approve your first tenant"
    echo -e "    3. Add tenant containers: bash install.sh --add-tenant <slug>"
  fi
}

main "$@"
