#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Track Any Device — Docker SWARM deployer  (tad.sh)
#
# Companion to install.sh (which deploys with Docker Compose). This script
# deploys the SAME platform as a Docker Swarm stack named "tad".
#
# Fresh deploy (interactive, auto-generates all secrets):
#   bash tad.sh
#
# Update to latest pinned versions (rolling redeploy, no prompts):
#   bash tad.sh --update
#
# Options:
#   --update      Re-pull + rolling-redeploy the stack + run migrations. No prompts.
#   --dir PATH    Override install directory
#                 (default: ./track-any-device under the current folder, or $TAD_DIR)
#   --dry-run     Print what would happen without making changes
#
# Run this from your deployment folder (the one that holds your other stacks /
# client.yml / server.yml). Everything this stack owns is created beneath a
# single `track-any-device/` subdirectory, so it never collides with the rest:
#     <deploy-folder>/
#       client.yml  server.yml  …            (your other stacks — untouched)
#       track-any-device/
#         tad.sh        (this script, persisted for --update)
#         tad.yml       (generated Swarm stack file)
#         .env.tad      (this stack's environment — never plain .env)
#         frpc.toml     (frp client config)
#         volumes/{mysql,influxdb,app_storage}   (local bind mounts)
#
# Ingress:
#   HTTP services (login, admin, api, graphql, soketi) are routed by your
#   EXISTING Traefik instance over the external `traefik-net` overlay, using
#   deploy labels (traefik.swarm.network=traefik-net, tls=true, dual Host rules).
#   This stack does NOT run its own Traefik and does NOT manage TLS certs.
#
# Topology (multi-node Swarm):
#   • Run this on a Swarm MANAGER node. A fresh host is bootstrapped into a
#     one-node swarm automatically.
#   • The node you run on is labelled tad.storage=true and becomes the
#     storage/control node. Stateful services (mysql, influxdb), the shared
#     app_storage and the migration runner (cron) are pinned there.
#   • Stateless services (api, graphql, queue, protocol servers, soketi …) run
#     on any node and reach the database/redis over the overlay network.
#   • Add worker nodes later with the `docker swarm join` command printed below.
# ──────────────────────────────────────────────────────────────────────────────

# Capture script path BEFORE set -u (undefined when piped via curl | bash).
SCRIPT_SELF="${BASH_SOURCE[0]:-}"

set -euo pipefail

# ── Offline fallback versions ─────────────────────────────────────────────────
# The script fetches real latest release tags from GitHub at runtime; these are
# only used when GitHub is unreachable.
# VERSIONS_START
TAD_SERVER_LOGIN_TAG="v0.4.3"
TAD_SERVER_ADMIN_TAG="v0.0.9"
TAD_SERVER_API_TAG="v0.1.424-ac19c5e0"
TAD_SERVER_GRAPHQL_TAG="v0.0.7"
TAD_SERVER_TENANT_TAG="latest"
TAD_SERVER_WEB_TAG="latest"
TAD_JT808_TAG="0.1.1"
TAD_GT06_TAG="0.1.1"
TAD_H02_TAG="0.1.1"
# VERSIONS_END

# Third-party pinned versions (upgrade intentionally)
MYSQL_VERSION="8.0.32"
REDIS_VERSION="7-alpine"
SOKETI_VERSION="1.4-16-alpine"
INFLUXDB_VERSION="2.7-alpine"
MAILPIT_VERSION="v1.24.0"
PMA_VERSION="5.2.2"
FRPC_VERSION="0.61.1"
# Note: TLS/ingress is handled by your EXISTING Traefik on the external
# `traefik-net` overlay — this stack does NOT ship its own Traefik.

# ── Static OAuth client credentials (seeded automatically by db:seed) ─────────
WEB_CLIENT_ID="tad_web_portal"
WEB_CLIENT_SECRET="tad_web_portal_secret"
MY_CLIENT_ID="tad_my_portal"
MY_CLIENT_SECRET="tad_my_portal_secret"
ADMIN_CLIENT_ID="tad_admin_panel"
ADMIN_CLIENT_SECRET="tad_admin_panel_secret"
GRAPHQL_CLIENT_ID="tad_graphql_api"
GRAPHQL_CLIENT_SECRET="tad_graphql_api_secret"
MOBILE_CLIENT_ID="tad_mobile_tad101"   # PKCE — no secret

# ── Config ────────────────────────────────────────────────────────────────────
# Default install dir is a `track-any-device/` folder under the CURRENT directory,
# so this stack sits beside (not on top of) the other stacks in your deploy folder.
INSTALL_DIR="${TAD_DIR:-$PWD/track-any-device}"
ORG="trackanydevice"
STACK="tad"                 # Swarm stack name (docker stack deploy ... tad)
NETWORK="tad"               # internal overlay network for service-to-service traffic
TRAEFIK_NET="traefik-net"   # EXTERNAL overlay your Traefik lives on (HTTP ingress)
DRY_RUN=false
UPDATE_ONLY=false
HAVE_EXISTING_ENV=false
FRPC_CONFIG_VERSION="init"  # content hash of frpc.toml, set by write_frpc_config

# ── Colours ───────────────────────────────────────────────────────────────────
BOLD="\033[1m"; RESET="\033[0m"
GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; CYAN="\033[36m"; DIM="\033[2m"

log()  { echo -e "${BOLD}${CYAN}[TAD]${RESET} $*"; }
ok()   { echo -e "${BOLD}${GREEN}  ✓${RESET}  $*"; }
warn() { echo -e "${BOLD}${YELLOW}  !${RESET}  $*"; }
err()  { echo -e "${BOLD}${RED}  ✗${RESET}  $*" >&2; }
dim()  { echo -e "${DIM}  $*${RESET}"; }
run()  { if $DRY_RUN; then echo -e "  ${YELLOW}[dry]${RESET} $*"; else eval "$*"; fi; }

# ── Parse arguments ───────────────────────────────────────────────────────────
for arg in "$@"; do
  case $arg in
    --update)  UPDATE_ONLY=true ;;
    --dry-run) DRY_RUN=true ;;
    --dir=*)   INSTALL_DIR="${arg#*=}" ;;
    --dir)     shift; INSTALL_DIR="$1" ;;
  esac
done

# Absolutise INSTALL_DIR — bind-mount source paths are baked into tad.yml and
# Swarm requires them to be absolute (relative paths would break on deploy).
case "$INSTALL_DIR" in
  /*) ;;                              # already absolute
  *)  INSTALL_DIR="$PWD/$INSTALL_DIR" ;;
esac

STACK_FILE="${INSTALL_DIR}/tad.yml"
ENV_FILE="${INSTALL_DIR}/.env.tad"
FRPC_FILE="${INSTALL_DIR}/frpc.toml"

# ── Dynamic version resolution ────────────────────────────────────────────────
_gh_latest() {
  local repo="$1" tag
  tag=$(curl -fsSL --max-time 5 \
    "https://api.github.com/repos/track-any-device/${repo}/releases/latest" \
    2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('tag_name',''))" \
    2>/dev/null || true)
  echo "$tag"
}

fetch_versions() {
  log "Fetching latest release versions from GitHub..."
  local login admin api graphql tenant web jt808 gt06 h02

  login=$(  _gh_latest "server-login")
  admin=$(   _gh_latest "server-admin")
  api=$(     _gh_latest "app")
  graphql=$( _gh_latest "server-graphql")
  tenant=$(  _gh_latest "server-tenant")
  web=$(     _gh_latest "web")
  jt808=$(   _gh_latest "server-jt808")
  gt06=$(    _gh_latest "server-gt06")
  h02=$(     _gh_latest "server-h02")

  [[ -n "$login"   ]] && TAD_SERVER_LOGIN_TAG="$login"     || warn "server-login:   using fallback ${TAD_SERVER_LOGIN_TAG}"
  [[ -n "$admin"   ]] && TAD_SERVER_ADMIN_TAG="$admin"     || warn "server-admin:   using fallback ${TAD_SERVER_ADMIN_TAG}"
  [[ -n "$api"     ]] && TAD_SERVER_API_TAG="$api"         || warn "server-api:     using fallback ${TAD_SERVER_API_TAG}"
  [[ -n "$graphql" ]] && TAD_SERVER_GRAPHQL_TAG="$graphql" || warn "server-graphql: using fallback ${TAD_SERVER_GRAPHQL_TAG}"
  [[ -n "$tenant"  ]] && TAD_SERVER_TENANT_TAG="$tenant"
  [[ -n "$web"     ]] && TAD_SERVER_WEB_TAG="$web"
  [[ -n "$jt808"   ]] && TAD_JT808_TAG="$jt808"
  [[ -n "$gt06"    ]] && TAD_GT06_TAG="$gt06"
  [[ -n "$h02"     ]] && TAD_H02_TAG="$h02"

  echo ""
  echo -e "${BOLD}── Resolved versions ───────────────────────────────────────────${RESET}"
  printf "  %-18s %s\n" "server-login:"    "${TAD_SERVER_LOGIN_TAG}"
  printf "  %-18s %s\n" "server-admin:"    "${TAD_SERVER_ADMIN_TAG}"
  printf "  %-18s %s\n" "server-api:"      "${TAD_SERVER_API_TAG}"
  printf "  %-18s %s\n" "server-graphql:"  "${TAD_SERVER_GRAPHQL_TAG}"
  printf "  %-18s %s\n" "jt808-server:"    "${TAD_JT808_TAG}"
  printf "  %-18s %s\n" "gt06-server:"     "${TAD_GT06_TAG}"
  printf "  %-18s %s\n" "h02-server:"      "${TAD_H02_TAG}"
  echo ""
}

# ── Helpers ───────────────────────────────────────────────────────────────────
ask() {
  local label="$1" default="${2:-}" _answer
  if [[ -n "$default" ]]; then
    printf "  %s [%s]: " "$label" "$default" >/dev/tty
  else
    printf "  %s: " "$label" >/dev/tty
  fi
  IFS= read -r _answer </dev/tty || true
  echo "${_answer:-$default}"
}

ask_secret() {
  local label="$1" _answer
  printf "  %s [auto-generate]: " "$label" >/dev/tty
  IFS= read -rs _answer </dev/tty || true
  echo "" >/dev/tty
  echo "$_answer"
}

confirm() {
  local label="$1" _answer
  printf "  %s [Y/n]: " "$label" >/dev/tty
  IFS= read -r _answer </dev/tty || true
  [[ "${_answer:-Y}" =~ ^[Yy]$ ]]
}

gen_password()  { openssl rand -base64 18 | tr -d '=+/'; }
gen_hex()       { openssl rand -hex 24; }
gen_app_key()   { echo "base64:$(openssl rand -base64 32)"; }
gen_pusher_id() { echo "tad-$(openssl rand -hex 6)"; }

# ── Prerequisites ─────────────────────────────────────────────────────────────
check_prerequisites() {
  log "Checking prerequisites..."
  local missing=()
  command -v docker  &>/dev/null || missing+=("docker")
  command -v openssl &>/dev/null || missing+=("openssl")

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required tools: ${missing[*]}"
    echo "  Install Docker: https://docs.docker.com/get-docker/"
    exit 1
  fi

  ok "Docker $(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)"
  # Deployment uses Docker Swarm (docker stack deploy), built into the engine —
  # the standalone `docker compose` plugin is NOT required by this script.

  # Ensure Docker can reach IPv6-only registries (e.g. quay.io) on IPv4 hosts.
  if [[ -f /etc/gai.conf ]] && ! grep -q "^precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null; then
    echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf 2>/dev/null || true
    ok "IPv4 preference set in /etc/gai.conf (fixes quay.io pull on IPv4-only hosts)"
  fi
}

# ── Ensure this host is a Swarm manager + labelled as storage node ────────────
ensure_swarm() {
  log "Checking Docker Swarm..."

  if $DRY_RUN; then
    echo "  [dry] Would ensure Swarm active + label local node tad.storage=true"
    return 0
  fi

  local state
  state=$(docker info --format '{{.Swarm.LocalState}}' 2>/dev/null || echo "inactive")

  if [[ "$state" != "active" ]]; then
    log "Initialising a new Swarm on this host..."
    local init_args=()
    [[ -n "${SWARM_ADVERTISE_ADDR:-}" ]] && init_args+=(--advertise-addr "${SWARM_ADVERTISE_ADDR}")
    if ! docker swarm init "${init_args[@]}" &>/dev/null; then
      err "docker swarm init failed."
      err "On a host with multiple IPs, set the address to advertise and re-run:"
      err "    SWARM_ADVERTISE_ADDR=<this-host-ip> bash tad.sh"
      exit 1
    fi
    ok "Swarm initialised"
  else
    ok "Swarm already active"
  fi

  if [[ "$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null)" != "true" ]]; then
    err "This node is part of a Swarm but is NOT a manager. Run tad.sh on a manager node."
    exit 1
  fi

  local node_id
  node_id=$(docker node inspect self --format '{{.ID}}' 2>/dev/null || true)
  if [[ -n "$node_id" ]]; then
    docker node update --label-add tad.storage=true "$node_id" &>/dev/null \
      && ok "Local node labelled tad.storage=true (storage/control node)"
  fi

  # The external ingress network must exist before deploy (services join it and
  # your Traefik routes over it). Create it if your Traefik stack hasn't yet.
  if docker network ls --format '{{.Name}}' 2>/dev/null | grep -qx "${TRAEFIK_NET}"; then
    ok "Ingress network '${TRAEFIK_NET}' present"
  else
    docker network create --driver overlay --attachable "${TRAEFIK_NET}" &>/dev/null \
      && ok "Created shared overlay network '${TRAEFIK_NET}' (attach your Traefik to it)" \
      || warn "Could not create '${TRAEFIK_NET}' — create it before deploy: docker network create --driver overlay --attachable ${TRAEFIK_NET}"
  fi

  echo ""
  dim "  To add worker nodes to this cluster, run on each worker:"
  dim "    $(docker swarm join-token worker 2>/dev/null | grep 'docker swarm join' || echo 'docker swarm join --token <token> <manager-ip>:2377')"
  echo ""
}

# ── Detect and load an existing .env ─────────────────────────────────────────
detect_existing_env() {
  local env_file="${ENV_FILE}"
  [[ -f "$env_file" ]] || return 0

  log "Loading existing configuration from ${env_file}..."
  set -a; source "$env_file" 2>/dev/null || true; set +a

  CFG_DOMAIN="${APP_DOMAIN:-}"
  CFG_SCHEME="https"
  CFG_LOGIN_DOMAIN="${LOGIN_DOMAIN:-login.${CFG_DOMAIN}}"
  CFG_ADMIN_DOMAIN="${ADMIN_DOMAIN:-admin.${CFG_DOMAIN}}"
  CFG_GRAPHQL_DOMAIN="${GRAPHQL_DOMAIN:-graphql.${CFG_DOMAIN}}"
  CFG_MYSQL_DB="${MYSQL_DATABASE:-tad}"
  CFG_MYSQL_USER="${MYSQL_USER:-tad}"
  CFG_MYSQL_ROOT_PASS="${MYSQL_ROOT_PASSWORD:-}"
  CFG_MYSQL_PASS="${MYSQL_PASSWORD:-}"
  CFG_SWARM_HOST_DOMAIN="${SWARM_HOST_DOMAIN:-host-swarm.net}"
  CFG_FRP_SERVER_ADDR="${FRP_SERVER_ADDR:-}"
  CFG_FRP_SERVER_PORT="${FRP_SERVER_PORT:-7000}"
  CFG_FRP_TOKEN="${FRP_TOKEN:-change-me}"
  CFG_JT808_HOST="${JT808_HOST:-}"
  CFG_JT808_PORT="${JT808_PORT:-7018}"
  CFG_GT06_HOST="${GT06_HOST:-}"
  CFG_GT06_PORT="${GT06_PORT:-7019}"
  CFG_H02_HOST="${H02_HOST:-}"
  CFG_H02_TCP_PORT="${H02_TCP_PORT:-7020}"
  CFG_H02_UDP_PORT="${H02_UDP_PORT:-7021}"
  CFG_SMS_URL="${SMS_GATEWAY_URL:-}"
  CFG_SMS_KEY="${SMS_GATEWAY_API_KEY:-}"
  CFG_SMS_NUMBER="${SMS_MASTER_NUMBER:-}"
  CFG_LOGIN_KEY="${LOGIN_APP_KEY:-}"
  CFG_ADMIN_KEY="${ADMIN_APP_KEY:-}"
  CFG_API_KEY="${API_APP_KEY:-}"
  CFG_GRAPHQL_KEY="${GRAPHQL_APP_KEY:-}"
  CFG_PUSHER_ID="${PUSHER_APP_ID:-}"
  CFG_PUSHER_KEY="${PUSHER_APP_KEY:-}"
  CFG_PUSHER_SECRET="${PUSHER_APP_SECRET:-}"
  CFG_INFLUX_PASS="${INFLUXDB_PASSWORD:-}"
  CFG_INFLUX_TOKEN="${INFLUXDB_TOKEN:-}"
  CFG_PASSPORT_PRIVATE="${PASSPORT_PRIVATE_KEY_B64:-}"
  CFG_PASSPORT_PUBLIC="${PASSPORT_PUBLIC_KEY_B64:-}"

  HAVE_EXISTING_ENV=true
  ok "Existing configuration loaded — all secrets and settings will be reused"
}

# ── Interactive configuration gathering ───────────────────────────────────────
collect_config() {
  if $HAVE_EXISTING_ENV; then
    echo ""
    echo -e "${BOLD}── Reusing existing configuration ──────────────────────────────${RESET}"
    echo ""
    echo "  Domain:      ${CFG_DOMAIN}"
    echo "  Swarm host:  *-tad.${CFG_SWARM_HOST_DOMAIN:-host-swarm.net}"
    echo "  Database:    ${CFG_MYSQL_USER}@mysql/${CFG_MYSQL_DB}"
    echo "  frp server:  ${CFG_FRP_SERVER_ADDR:-(not configured)}:${CFG_FRP_SERVER_PORT:-7000}"
    echo "  SMS URL:     ${CFG_SMS_URL:-(not configured)}"
    echo ""
    [[ -z "${CFG_LOGIN_KEY:-}"     ]] && CFG_LOGIN_KEY=$(gen_app_key)   && ok "Login app key (generated)"
    [[ -z "${CFG_ADMIN_KEY:-}"     ]] && CFG_ADMIN_KEY=$(gen_app_key)   && ok "Admin app key (generated)"
    [[ -z "${CFG_API_KEY:-}"       ]] && CFG_API_KEY=$(gen_app_key)     && ok "API app key (generated)"
    [[ -z "${CFG_GRAPHQL_KEY:-}"   ]] && CFG_GRAPHQL_KEY=$(gen_app_key) && ok "GraphQL app key (generated)"
    [[ -z "${CFG_PUSHER_ID:-}"     ]] && CFG_PUSHER_ID=$(gen_pusher_id)
    [[ -z "${CFG_PUSHER_KEY:-}"    ]] && CFG_PUSHER_KEY=$(gen_hex)
    [[ -z "${CFG_PUSHER_SECRET:-}" ]] && CFG_PUSHER_SECRET=$(gen_hex)
    [[ -z "${CFG_INFLUX_PASS:-}"   ]] && CFG_INFLUX_PASS=$(gen_password)
    [[ -z "${CFG_INFLUX_TOKEN:-}"  ]] && CFG_INFLUX_TOKEN=$(gen_hex)
    : "${CFG_FRP_SERVER_PORT:=7000}"
    : "${CFG_FRP_TOKEN:=change-me}"
    : "${CFG_SWARM_HOST_DOMAIN:=host-swarm.net}"
    if [[ -z "${CFG_PASSPORT_PRIVATE:-}" ]]; then
      echo -ne "  Generating Passport RSA keys (4096-bit)..." >/dev/tty
      local priv_pem
      priv_pem=$(openssl genrsa 4096 2>/dev/null)
      CFG_PASSPORT_PRIVATE=$(echo "$priv_pem" | openssl base64 -A)
      CFG_PASSPORT_PUBLIC=$(echo "$priv_pem" | openssl rsa -pubout 2>/dev/null | openssl base64 -A)
      echo " done" >/dev/tty
      ok "Passport RSA key pair (generated)"
    fi
    return 0
  fi

  echo ""
  echo -e "${BOLD}── Step 1/4 — Domains & ingress ────────────────────────────────${RESET}"
  echo ""
  CFG_DOMAIN=$(ask "Main domain" "track-any-device.com")
  CFG_SCHEME="https"
  CFG_LOGIN_DOMAIN="login.${CFG_DOMAIN}"
  CFG_ADMIN_DOMAIN="admin.${CFG_DOMAIN}"
  CFG_GRAPHQL_DOMAIN="graphql.${CFG_DOMAIN}"
  CFG_SWARM_HOST_DOMAIN=$(ask "Swarm host domain (for *-tad.<domain> router hostnames)" "host-swarm.net")

  echo ""
  dim "  Your existing Traefik (on external network '${TRAEFIK_NET}') will route,"
  dim "  with TLS (tls=true), each service on BOTH a swarm-host name and the real domain:"
  dim "    Login:    login-tad.${CFG_SWARM_HOST_DOMAIN}    | ${CFG_LOGIN_DOMAIN}"
  dim "    Admin:    admin-tad.${CFG_SWARM_HOST_DOMAIN}    | ${CFG_ADMIN_DOMAIN}"
  dim "    GraphQL:  graphql-tad.${CFG_SWARM_HOST_DOMAIN}  | ${CFG_GRAPHQL_DOMAIN}"
  dim "    API:      api-tad.${CFG_SWARM_HOST_DOMAIN}      | api.${CFG_DOMAIN}"
  dim "    Realtime: ws-tad.${CFG_SWARM_HOST_DOMAIN}       | ws.${CFG_DOMAIN}"
  echo ""

  echo -e "${BOLD}── Step 2/4 — Database ─────────────────────────────────────────${RESET}"
  echo ""
  CFG_MYSQL_DB=$(ask "Database name" "tad")
  CFG_MYSQL_USER=$(ask "Database user" "tad")
  local root_input
  root_input=$(ask_secret "MySQL root password (blank to auto-generate)")
  CFG_MYSQL_ROOT_PASS="${root_input:-$(gen_password)}"
  local pass_input
  pass_input=$(ask_secret "MySQL user password (blank to auto-generate)")
  CFG_MYSQL_PASS="${pass_input:-$(gen_password)}"
  ok "Database: ${CFG_MYSQL_USER}@mysql/${CFG_MYSQL_DB}"

  echo ""
  echo -e "${BOLD}── Step 3/4 — frp tunnel & device endpoints ────────────────────${RESET}"
  echo ""
  dim "  frp publishes the JT808 TCP port through a public frps server."
  CFG_FRP_SERVER_ADDR=$(ask "frps server address (public IP/host of your frp server)")
  CFG_FRP_SERVER_PORT=$(ask "frps server port" "7000")
  CFG_FRP_TOKEN=$(ask   "frp auth token" "change-me")

  CFG_JT808_HOST=$(ask "JT808 host to send in device setup SMS (blank = use APP_DOMAIN)")
  CFG_JT808_PORT=$(ask "JT808 port to send in device setup SMS" "7018")
  CFG_GT06_HOST=$(ask "GT06/Concox host for setup SMS (blank = use APP_DOMAIN)")
  CFG_GT06_PORT=$(ask "GT06 TCP port" "7019")
  CFG_H02_HOST=$(ask "H02/Sinotrack host for setup SMS (blank = use APP_DOMAIN)")
  CFG_H02_TCP_PORT=$(ask "H02 TCP port" "7020")
  CFG_H02_UDP_PORT=$(ask "H02 UDP port" "7021")

  CFG_SMS_URL=$(ask "SMS Gateway URL (blank to skip)")
  CFG_SMS_KEY=""
  CFG_SMS_NUMBER=""
  if [[ -n "${CFG_SMS_URL}" ]]; then
    CFG_SMS_KEY=$(ask "SMS Gateway API key")
    CFG_SMS_NUMBER=$(ask "SMS master number (e.g. +92300000000)")
  fi

  echo ""
  echo -e "${BOLD}── Step 4/4 — Generating secrets ───────────────────────────────${RESET}"
  echo ""
  CFG_LOGIN_KEY=$(gen_app_key);   ok "Login app key"
  CFG_ADMIN_KEY=$(gen_app_key);   ok "Admin app key"
  CFG_API_KEY=$(gen_app_key);     ok "API app key"
  CFG_GRAPHQL_KEY=$(gen_app_key); ok "GraphQL app key"
  CFG_PUSHER_ID=$(gen_pusher_id)
  CFG_PUSHER_KEY=$(gen_hex)
  CFG_PUSHER_SECRET=$(gen_hex)
  ok "Pusher credentials  (ID: ${CFG_PUSHER_ID})"
  CFG_INFLUX_PASS=$(gen_password)
  CFG_INFLUX_TOKEN=$(gen_hex)
  ok "InfluxDB credentials"

  echo -ne "  Generating Passport RSA keys (4096-bit)..." >/dev/tty
  local priv_pem
  priv_pem=$(openssl genrsa 4096 2>/dev/null)
  CFG_PASSPORT_PRIVATE=$(echo "$priv_pem" | openssl base64 -A)
  CFG_PASSPORT_PUBLIC=$(echo "$priv_pem" | openssl rsa -pubout 2>/dev/null | openssl base64 -A)
  echo " done" >/dev/tty
  ok "Passport RSA key pair"

  echo ""
  echo -e "${BOLD}── Configuration summary ───────────────────────────────────────${RESET}"
  echo ""
  echo "  Install directory:  ${INSTALL_DIR}"
  echo "  Swarm stack:        ${STACK}"
  echo "  Ingress network:    ${TRAEFIK_NET} (external — your Traefik)"
  echo "  Domain:             ${CFG_DOMAIN}"
  echo "  Swarm host domain:  ${CFG_SWARM_HOST_DOMAIN}"
  echo "  Database:           ${CFG_MYSQL_USER}@mysql/${CFG_MYSQL_DB}"
  echo "  frp server:         ${CFG_FRP_SERVER_ADDR:-(skipped)}:${CFG_FRP_SERVER_PORT}"
  echo "  SMS Gateway:        ${CFG_SMS_URL:-(skipped)}"
  echo ""
  if ! confirm "Proceed with Swarm deployment?"; then
    echo "Aborted."
    exit 0
  fi
}

# ── Write fully-populated .env ─────────────────────────────────────────────────
write_env() {
  local env_file="${ENV_FILE}"

  if [[ -f "$env_file" ]] && ! $HAVE_EXISTING_ENV; then
    warn ".env already exists — skipping. Delete it to reconfigure, or edit directly."
    set -a; source "$env_file" 2>/dev/null || true; set +a
    return
  fi

  log "Writing ${env_file}..."
  if $DRY_RUN; then
    echo "  [dry] Would write complete .env to ${env_file}"
    return
  fi

  cat > "$env_file" <<ENV
# ──────────────────────────────────────────────────────────────────────────────
# Track Any Device — Platform Environment (Docker Swarm)
# Generated by tad.sh on $(date -u +"%Y-%m-%d %H:%M UTC")
# ──────────────────────────────────────────────────────────────────────────────

# ── Domains & ingress ─────────────────────────────────────────────────────────
APP_DOMAIN=${CFG_DOMAIN}
LOGIN_DOMAIN=${CFG_LOGIN_DOMAIN}
ADMIN_DOMAIN=${CFG_ADMIN_DOMAIN}
GRAPHQL_DOMAIN=${CFG_GRAPHQL_DOMAIN}
SESSION_DOMAIN=.${CFG_DOMAIN}
# Swarm host domain → Traefik router hostnames are <svc>-tad.<this>
SWARM_HOST_DOMAIN=${CFG_SWARM_HOST_DOMAIN}

# ── App encryption keys ───────────────────────────────────────────────────────
LOGIN_APP_KEY=${CFG_LOGIN_KEY}
ADMIN_APP_KEY=${CFG_ADMIN_KEY}
API_APP_KEY=${CFG_API_KEY}
GRAPHQL_APP_KEY=${CFG_GRAPHQL_KEY}

# ── Database ──────────────────────────────────────────────────────────────────
MYSQL_ROOT_PASSWORD=${CFG_MYSQL_ROOT_PASS}
MYSQL_DATABASE=${CFG_MYSQL_DB}
MYSQL_USER=${CFG_MYSQL_USER}
MYSQL_PASSWORD=${CFG_MYSQL_PASS}

# ── Real-time (Pusher / Soketi) ───────────────────────────────────────────────
PUSHER_APP_ID=${CFG_PUSHER_ID}
PUSHER_APP_KEY=${CFG_PUSHER_KEY}
PUSHER_APP_SECRET=${CFG_PUSHER_SECRET}

# ── Time-series telemetry (InfluxDB) ─────────────────────────────────────────
INFLUXDB_USER=admin
INFLUXDB_PASSWORD=${CFG_INFLUX_PASS}
INFLUXDB_ORG=track-any-device
INFLUXDB_BUCKET=device_locations
INFLUXDB_TOKEN=${CFG_INFLUX_TOKEN}

# ── Passport OAuth2 RSA keys ──────────────────────────────────────────────────
PASSPORT_PRIVATE_KEY_B64=${CFG_PASSPORT_PRIVATE}
PASSPORT_PUBLIC_KEY_B64=${CFG_PASSPORT_PUBLIC}

# ── Static OAuth clients (seeded by php artisan db:seed) ──────────────────────
WEB_SSO_CLIENT_ID=${WEB_CLIENT_ID}
WEB_SSO_CLIENT_SECRET=${WEB_CLIENT_SECRET}
MY_SSO_CLIENT_ID=${MY_CLIENT_ID}
MY_SSO_CLIENT_SECRET=${MY_CLIENT_SECRET}
ADMIN_SSO_CLIENT_ID=${ADMIN_CLIENT_ID}
ADMIN_SSO_CLIENT_SECRET=${ADMIN_CLIENT_SECRET}
GRAPHQL_SSO_CLIENT_ID=${GRAPHQL_CLIENT_ID}
GRAPHQL_SSO_CLIENT_SECRET=${GRAPHQL_CLIENT_SECRET}
MOBILE_CLIENT_ID=${MOBILE_CLIENT_ID}

# ── SMS Gateway (optional) ────────────────────────────────────────────────────
SMS_GATEWAY_URL=${CFG_SMS_URL:-}
SMS_GATEWAY_API_KEY=${CFG_SMS_KEY:-}
SMS_MASTER_NUMBER=${CFG_SMS_NUMBER:-}

# ── JT808 device configuration (embedded in setup SMS) ───────────────────────
JT808_HOST=${CFG_JT808_HOST:-}
JT808_PORT=${CFG_JT808_PORT:-7018}
JT808_DEVICE_TYPE_ID=1

# ── GT06/Concox device configuration ─────────────────────────────────────────
GT06_HOST=${CFG_GT06_HOST:-}
GT06_PORT=${CFG_GT06_PORT:-7019}

# ── H02/Sinotrack device configuration ───────────────────────────────────────
H02_HOST=${CFG_H02_HOST:-}
H02_TCP_PORT=${CFG_H02_TCP_PORT:-7020}
H02_UDP_PORT=${CFG_H02_UDP_PORT:-7021}

# ── GraphQL M2M bearer token ──────────────────────────────────────────────────
GRAPHQL_KEY=
GRAPHQL_SECRET=

# ── frp tunnel (publishes JT808 TCP via a public frps server) ─────────────────
FRP_SERVER_ADDR=${CFG_FRP_SERVER_ADDR:-}
FRP_SERVER_PORT=${CFG_FRP_SERVER_PORT:-7000}
FRP_TOKEN=${CFG_FRP_TOKEN:-change-me}
ENV

  ok ".env written — all secrets generated, no manual editing required"
  MYSQL_ROOT_PASSWORD="${CFG_MYSQL_ROOT_PASS}"
}

# ── Patch missing vars into an existing .env (used by --update) ──────────────
patch_env() {
  local env_file="${ENV_FILE}"
  [[ -f "$env_file" ]] || return 0
  $DRY_RUN && { echo "  [dry] Would patch missing vars into ${env_file}"; return 0; }

  local patched=false
  _ensure_var() {
    local key="$1" default="$2"
    if ! grep -q "^${key}=" "$env_file" 2>/dev/null; then
      echo "${key}=${default}" >> "$env_file"
      ok "Added ${key}=${default} to .env"
      patched=true
    fi
  }

  _ensure_var "SWARM_HOST_DOMAIN" "host-swarm.net"
  _ensure_var "FRP_SERVER_ADDR"   ""
  _ensure_var "FRP_SERVER_PORT"   "7000"
  _ensure_var "FRP_TOKEN"         "change-me"
  _ensure_var "GT06_HOST"         ""
  _ensure_var "GT06_PORT"         "7019"
  _ensure_var "H02_HOST"          ""
  _ensure_var "H02_TCP_PORT"      "7020"
  _ensure_var "H02_UDP_PORT"      "7021"
  _ensure_var "SMS_GATEWAY_URL"   ""
  _ensure_var "SMS_GATEWAY_API_KEY" ""
  _ensure_var "SMS_MASTER_NUMBER" ""

  $patched && log "New env vars added to ${env_file}"
  return 0
}

# ── Directory structure (bind-mount data lives under <install>/volumes) ───────
create_directories() {
  log "Creating directory structure at ${INSTALL_DIR}..."
  run "mkdir -p '${INSTALL_DIR}'"
  run "mkdir -p '${INSTALL_DIR}/volumes/mysql'"
  run "mkdir -p '${INSTALL_DIR}/volumes/influxdb'"
  run "mkdir -p '${INSTALL_DIR}/volumes/app_storage'"
  if ! $DRY_RUN; then
    chmod -R 775 "${INSTALL_DIR}/volumes" 2>/dev/null || true
  fi
  ok "Directories ready"
}

# ── frp client config (delivered to the frpc task as a Docker config) ─────────
write_frpc_config() {
  if $DRY_RUN; then
    echo "  [dry] Would write ${FRPC_FILE} and compute its config version"
    FRPC_CONFIG_VERSION="dryrun"
    return
  fi

  log "Writing frp client config (${FRPC_FILE})..."
  set -a; source "${ENV_FILE}" 2>/dev/null || true; set +a

  cat > "${FRPC_FILE}" <<FRPC
# Auto-generated by tad.sh — frp client config (frp v0.61, TOML).
# Publishes the JT808 TCP port through the public frps server so GPS trackers
# can reach the jt808 service (resolved over the Swarm overlay network).
serverAddr = "${FRP_SERVER_ADDR:-}"
serverPort = ${FRP_SERVER_PORT:-7000}

auth.method = "token"
auth.token  = "${FRP_TOKEN:-change-me}"

[[proxies]]
name = "jt808"
type = "tcp"
localIP = "jt808"
localPort = 7018
remotePort = ${JT808_PORT:-7018}
FRPC

  # Swarm configs are immutable; version the config name by content hash so a
  # changed frpc.toml produces a new config on --update instead of being ignored.
  FRPC_CONFIG_VERSION=$( (sha1sum "${FRPC_FILE}" 2>/dev/null || shasum "${FRPC_FILE}") | cut -c1-8 )
  ok "frp config written (version ${FRPC_CONFIG_VERSION})"
}

# ── Swarm stack file generation ───────────────────────────────────────────────
generate_stack() {
  log "Generating Swarm stack file (${STACK_FILE}) — API: ${TAD_SERVER_API_TAG}..."

  if $DRY_RUN; then
    echo "  [dry] Would write ${STACK_FILE}"
    return
  fi

  cat > "${STACK_FILE}" <<STACK
# Auto-generated by tad.sh — do not edit manually.
# Regenerate/redeploy with: bash tad.sh --update
# Deploy with:  set -a; source .env.tad; set +a; docker stack deploy -c tad.yml ${STACK}
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
#
# Versions:  login=${TAD_SERVER_LOGIN_TAG}  admin=${TAD_SERVER_ADMIN_TAG}
#            api=${TAD_SERVER_API_TAG}  graphql=${TAD_SERVER_GRAPHQL_TAG}
#            jt808=${TAD_JT808_TAG}  gt06=${TAD_GT06_TAG}  h02=${TAD_H02_TAG}

x-deploy-any: &deploy-any
  replicas: 1
  restart_policy: { condition: any }

x-deploy-storage: &deploy-storage
  replicas: 1
  restart_policy: { condition: any }
  placement:
    constraints: ["node.labels.tad.storage == true"]

# Resource tiers — tune to your nodes. limits = hard cap; reservations = the
# amount the scheduler guarantees (reservations across all tasks must fit a node).
x-res-app: &res-app
  limits:       { cpus: "4", memory: "5120M" }
  reservations: { cpus: "1", memory: "512M" }
x-res-worker: &res-worker
  limits:       { cpus: "2", memory: "2048M" }
  reservations: { cpus: "0.5", memory: "256M" }
x-res-db: &res-db
  limits:       { cpus: "4", memory: "4096M" }
  reservations: { cpus: "1", memory: "1024M" }
x-res-small: &res-small
  limits:       { cpus: "1", memory: "512M" }
  reservations: { cpus: "0.25", memory: "128M" }

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
  DB_HOST:       mysql
  DB_PORT:       3306
  DB_DATABASE:   \${MYSQL_DATABASE}
  DB_USERNAME:   \${MYSQL_USER}
  DB_PASSWORD:   \${MYSQL_PASSWORD}
  CACHE_STORE:      redis
  QUEUE_CONNECTION: redis
  SESSION_DRIVER:   redis
  REDIS_HOST: redis
  REDIS_PORT: 6379
  BROADCAST_CONNECTION: pusher
  PUSHER_APP_ID:     \${PUSHER_APP_ID}
  PUSHER_APP_KEY:    \${PUSHER_APP_KEY}
  PUSHER_APP_SECRET: \${PUSHER_APP_SECRET}
  PUSHER_HOST:       soketi
  PUSHER_PORT:       6001
  PUSHER_SCHEME:     http
  PUSHER_APP_CLUSTER: mt1
  MAIL_MAILER: smtp
  MAIL_HOST:   mailtrap
  MAIL_PORT:   1025
  MAIL_FROM_ADDRESS: noreply@\${APP_DOMAIN}
  INFLUXDB_HOST:   influxdb
  INFLUXDB_PORT:   8086
  INFLUXDB_BUCKET: \${INFLUXDB_BUCKET:-device_locations}
  INFLUXDB_ORG:    \${INFLUXDB_ORG:-track-any-device}
  INFLUXDB_TOKEN:  \${INFLUXDB_TOKEN}
  PASSPORT_PRIVATE_KEY_B64: \${PASSPORT_PRIVATE_KEY_B64}
  PASSPORT_PUBLIC_KEY_B64:  \${PASSPORT_PUBLIC_KEY_B64}
  SMS_GATEWAY_URL:     \${SMS_GATEWAY_URL:-}
  SMS_GATEWAY_API_KEY: \${SMS_GATEWAY_API_KEY:-}
  SMS_MASTER_NUMBER:   \${SMS_MASTER_NUMBER:-}

services:

  # ── SSO Identity Provider ────────────────────────────────────────────────────
  login:
    image: ${ORG}/server-login:latest
    networks: [tad, traefik-net]
    volumes:
      - ${INSTALL_DIR}/volumes/app_storage:/app/storage/app
    environment:
      <<: *app-env
      APP_SURFACE: login
      APP_URL: https://\${LOGIN_DOMAIN}
      APP_KEY: \${LOGIN_APP_KEY}
      SESSION_COOKIE: login_session
    deploy:
      <<: *deploy-storage
      resources: *res-app
      labels:
        - "traefik.enable=true"
        - "traefik.swarm.network=${TRAEFIK_NET}"
        - "traefik.http.services.tad-login.loadbalancer.server.port=80"
        - "traefik.http.routers.tad-login.rule=Host(\`login-tad.\${SWARM_HOST_DOMAIN}\`) || Host(\`\${LOGIN_DOMAIN}\`)"
        - "traefik.http.routers.tad-login.entrypoints=websecure"
        - "traefik.http.routers.tad-login.tls=true"
        - "traefik.http.routers.tad-login.service=tad-login"

  # ── Filament Admin Panel ─────────────────────────────────────────────────────
  admin:
    image: ${ORG}/server-admin:latest
    networks: [tad, traefik-net]
    volumes:
      - ${INSTALL_DIR}/volumes/app_storage:/app/storage/app
    environment:
      <<: *app-env
      APP_SURFACE: admin
      APP_URL: https://\${ADMIN_DOMAIN}
      APP_KEY: \${ADMIN_APP_KEY}
      SESSION_COOKIE: admin_session
      SSO_SERVER_URL: https://\${LOGIN_DOMAIN}
    deploy:
      <<: *deploy-storage
      resources: *res-app
      labels:
        - "traefik.enable=true"
        - "traefik.swarm.network=${TRAEFIK_NET}"
        - "traefik.http.services.tad-admin.loadbalancer.server.port=80"
        - "traefik.http.routers.tad-admin.rule=Host(\`admin-tad.\${SWARM_HOST_DOMAIN}\`) || Host(\`\${ADMIN_DOMAIN}\`)"
        - "traefik.http.routers.tad-admin.entrypoints=websecure"
        - "traefik.http.routers.tad-admin.tls=true"
        - "traefik.http.routers.tad-admin.service=tad-admin"

  # ── Central REST API Server ──────────────────────────────────────────────────
  api:
    image: ${ORG}/server-api:latest
    networks: [tad, traefik-net]
    environment:
      <<: *app-env
      APP_SURFACE: api
      APP_URL: https://api.\${APP_DOMAIN}
      APP_KEY: \${API_APP_KEY}
      SSO_SERVER_URL: https://\${LOGIN_DOMAIN}
      LOG_CHANNEL: stderr
      JT808_HOST: \${JT808_HOST:-}
      JT808_PORT: \${JT808_PORT:-7018}
      GT06_HOST:  \${GT06_HOST:-}
      GT06_PORT:  \${GT06_PORT:-7019}
      H02_HOST:   \${H02_HOST:-}
      H02_TCP_PORT: \${H02_TCP_PORT:-7020}
      H02_UDP_PORT: \${H02_UDP_PORT:-7021}
    deploy:
      <<: *deploy-any
      resources: *res-app
      labels:
        - "traefik.enable=true"
        - "traefik.swarm.network=${TRAEFIK_NET}"
        - "traefik.http.services.tad-api.loadbalancer.server.port=80"
        - "traefik.http.routers.tad-api.rule=Host(\`api-tad.\${SWARM_HOST_DOMAIN}\`) || Host(\`api.\${APP_DOMAIN}\`)"
        - "traefik.http.routers.tad-api.entrypoints=websecure"
        - "traefik.http.routers.tad-api.tls=true"
        - "traefik.http.routers.tad-api.service=tad-api"

  # ── GraphQL API ──────────────────────────────────────────────────────────────
  graphql:
    image: ${ORG}/server-graphql:latest
    networks: [tad, traefik-net]
    environment:
      <<: *app-env
      APP_SURFACE: graphql
      APP_URL: https://\${GRAPHQL_DOMAIN}
      APP_KEY: \${GRAPHQL_APP_KEY}
      SESSION_COOKIE: graphql_session
      SSO_SERVER_URL: https://\${LOGIN_DOMAIN}
      GRAPHQL_KEY:    \${GRAPHQL_KEY:-}
      GRAPHQL_SECRET: \${GRAPHQL_SECRET:-}
    deploy:
      <<: *deploy-any
      resources: *res-app
      labels:
        - "traefik.enable=true"
        - "traefik.swarm.network=${TRAEFIK_NET}"
        - "traefik.http.services.tad-graphql.loadbalancer.server.port=80"
        - "traefik.http.routers.tad-graphql.rule=Host(\`graphql-tad.\${SWARM_HOST_DOMAIN}\`) || Host(\`\${GRAPHQL_DOMAIN}\`)"
        - "traefik.http.routers.tad-graphql.entrypoints=websecure"
        - "traefik.http.routers.tad-graphql.tls=true"
        - "traefik.http.routers.tad-graphql.service=tad-graphql"

  # ── Scheduler (also the migration runner — pinned to storage node) ───────────
  cron:
    image: ${ORG}/server-cron:latest
    networks: [tad]
    environment:
      <<: *app-env
      APP_SURFACE: api
      APP_KEY: \${API_APP_KEY}
      LOG_CHANNEL: stderr
      JT808_HOST: \${JT808_HOST:-}
      JT808_PORT: \${JT808_PORT:-7018}
      GT06_HOST:  \${GT06_HOST:-}
      GT06_PORT:  \${GT06_PORT:-7019}
      H02_HOST:   \${H02_HOST:-}
      H02_TCP_PORT: \${H02_TCP_PORT:-7020}
      H02_UDP_PORT: \${H02_UDP_PORT:-7021}
    deploy:
      <<: *deploy-storage
      resources: *res-worker

  # ── Queue worker ─────────────────────────────────────────────────────────────
  queue:
    image: ${ORG}/server-queue:latest
    networks: [tad]
    environment:
      <<: *app-env
      APP_SURFACE: api
      APP_KEY: \${API_APP_KEY}
      LOG_CHANNEL: stderr
      JT808_HOST: \${JT808_HOST:-}
      JT808_PORT: \${JT808_PORT:-7018}
      GT06_HOST:  \${GT06_HOST:-}
      GT06_PORT:  \${GT06_PORT:-7019}
      H02_HOST:   \${H02_HOST:-}
      H02_TCP_PORT: \${H02_TCP_PORT:-7020}
      H02_UDP_PORT: \${H02_UDP_PORT:-7021}
    deploy:
      <<: *deploy-any
      resources: *res-worker

  cli:
    image: ${ORG}/server-cli:latest
    networks: [tad]
    environment:
      <<: *app-env
      APP_KEY: \${API_APP_KEY}
    deploy:
      <<: *deploy-any
      resources: *res-worker

  # ── JT808 GPS TCP Server (published via frp; host-mode port for source IP) ───
  jt808:
    image: ${ORG}/jt808-server:latest
    networks: [tad]
    ports:
      - { target: 7018, published: 7018, protocol: tcp, mode: host }
      - "9090:9090"
    environment:
      JT808_TCP_ADDR:    :7018
      JT808_HTTP_ADDR:   :9090
      REDIS_HOST: redis
      REDIS_PORT: 6379
      STREAM_KEY: jt808:telemetry
      STREAM_MAX_LEN: "100000"
      SESSION_PREFIX:    "jt808:session:"
      AUTH_TOKEN_PREFIX: "jt808:authtoken:"
      ONLINE_Z_KEY: jt808:online
      CMD_CHANNEL:  "jt808:cmd:"
      AUTH_TIMEOUT:      30s
      HEARTBEAT_TIMEOUT: 3m
      DB_HOST:      mysql
      DB_PORT:      3306
      DB_DATABASE:  \${MYSQL_DATABASE}
      DB_USERNAME:  \${MYSQL_USER}
      DB_PASSWORD:  \${MYSQL_PASSWORD}
      DB_DEVICE_TYPE_ID: \${JT808_DEVICE_TYPE_ID:-1}
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:9090/healthz || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    deploy:
      <<: *deploy-any
      resources: *res-small

  gt06:
    image: ${ORG}/server-gt06:latest
    networks: [tad]
    ports:
      - { target: 7019, published: 7019, protocol: tcp, mode: host }
    environment:
      GT06_TCP_ADDR:  :7019
      GT06_HTTP_ADDR: :9091
      REDIS_HOST:     redis
      REDIS_PORT:     6379
      REDIS_GT06_DB:  1
      STREAM_KEY:     gt06:telemetry
      STREAM_MAX_LEN: "100000"
      CMD_CHANNEL:    "gt06:cmd:"
      DB_ENABLED:     "true"
      DB_HOST:        mysql
      DB_PORT:        3306
      DB_DATABASE:    \${MYSQL_DATABASE}
      DB_USERNAME:    \${MYSQL_USER}
      DB_PASSWORD:    \${MYSQL_PASSWORD}
      DB_DEVICE_TYPE_ID: 2
    deploy:
      <<: *deploy-any
      resources: *res-small

  h02-tcp:
    image: ${ORG}/server-h02-tcp:latest
    networks: [tad]
    ports:
      - { target: 7020, published: 7020, protocol: tcp, mode: host }
    environment:
      H02_TCP_ADDR:      :7020
      H02_TCP_HTTP_ADDR: :9092
      REDIS_HOST:        redis
      REDIS_PORT:        6379
      REDIS_H02_DB:      2
      STREAM_KEY:        h02:telemetry
      STREAM_MAX_LEN:    "100000"
      CMD_CHANNEL:       "h02:cmd:"
      DB_ENABLED:        "true"
      DB_HOST:           mysql
      DB_PORT:           3306
      DB_DATABASE:       \${MYSQL_DATABASE}
      DB_USERNAME:       \${MYSQL_USER}
      DB_PASSWORD:       \${MYSQL_PASSWORD}
      DB_DEVICE_TYPE_ID: 3
    deploy:
      <<: *deploy-any
      resources: *res-small

  h02-udp:
    image: ${ORG}/server-h02-udp:latest
    networks: [tad]
    ports:
      - { target: 7021, published: 7021, protocol: udp, mode: host }
    environment:
      H02_UDP_ADDR:      :7021
      H02_UDP_HTTP_ADDR: :9093
      REDIS_HOST:        redis
      REDIS_PORT:        6379
      REDIS_H02_DB:      2
      STREAM_KEY:        h02:telemetry
      STREAM_MAX_LEN:    "100000"
      DB_ENABLED:        "true"
      DB_HOST:           mysql
      DB_PORT:           3306
      DB_DATABASE:       \${MYSQL_DATABASE}
      DB_USERNAME:       \${MYSQL_USER}
      DB_PASSWORD:       \${MYSQL_PASSWORD}
      DB_DEVICE_TYPE_ID: 3
    deploy:
      <<: *deploy-any
      resources: *res-small

  # ── Infrastructure ───────────────────────────────────────────────────────────
  mysql:
    image: mysql:${MYSQL_VERSION}
    init: true
    networks: [tad]
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE:      \${MYSQL_DATABASE}
      MYSQL_USER:          \${MYSQL_USER}
      MYSQL_PASSWORD:      \${MYSQL_PASSWORD}
    ports: ["3306:3306"]
    volumes:
      - ${INSTALL_DIR}/volumes/mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p\${MYSQL_ROOT_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 10
    deploy:
      <<: *deploy-storage
      resources: *res-db

  redis:
    image: redis:${REDIS_VERSION}
    networks: [tad]
    ports: ["6379:6379"]
    deploy:
      <<: *deploy-any
      resources: *res-small

  soketi:
    image: quay.io/soketi/soketi:${SOKETI_VERSION}
    networks: [tad, traefik-net]
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
    deploy:
      <<: *deploy-any
      resources: *res-small
      labels:
        - "traefik.enable=true"
        - "traefik.swarm.network=${TRAEFIK_NET}"
        - "traefik.http.services.tad-soketi.loadbalancer.server.port=6001"
        - "traefik.http.routers.tad-soketi.rule=Host(\`ws-tad.\${SWARM_HOST_DOMAIN}\`) || Host(\`ws.\${APP_DOMAIN}\`)"
        - "traefik.http.routers.tad-soketi.entrypoints=websecure"
        - "traefik.http.routers.tad-soketi.tls=true"
        - "traefik.http.routers.tad-soketi.service=tad-soketi"

  influxdb:
    image: influxdb:${INFLUXDB_VERSION}
    networks: [tad]
    ports: ["8086:8086"]
    volumes:
      - ${INSTALL_DIR}/volumes/influxdb:/var/lib/influxdb2
    environment:
      DOCKER_INFLUXDB_INIT_MODE:        setup
      DOCKER_INFLUXDB_INIT_USERNAME:    \${INFLUXDB_USER:-admin}
      DOCKER_INFLUXDB_INIT_PASSWORD:    \${INFLUXDB_PASSWORD}
      DOCKER_INFLUXDB_INIT_ORG:         \${INFLUXDB_ORG:-track-any-device}
      DOCKER_INFLUXDB_INIT_BUCKET:      \${INFLUXDB_BUCKET:-device_locations}
      DOCKER_INFLUXDB_INIT_ADMIN_TOKEN: \${INFLUXDB_TOKEN}
    deploy:
      <<: *deploy-storage
      resources: *res-db

  mailtrap:
    image: axllent/mailpit:${MAILPIT_VERSION}
    networks: [tad]
    ports: ["1025:1025", "8025:8025"]
    deploy:
      <<: *deploy-any
      resources: *res-small

  pma:
    image: phpmyadmin/phpmyadmin:${PMA_VERSION}
    networks: [tad]
    ports: ["3333:80"]
    environment:
      PMA_HOST:     mysql
      PMA_USER:     \${MYSQL_USER}
      PMA_PASSWORD: \${MYSQL_PASSWORD}
    deploy:
      <<: *deploy-any
      resources: *res-small

  # ── frp tunnel — publishes JT808 TCP through a public frps server ────────────
  frpc:
    image: snowdreamtech/frpc:${FRPC_VERSION}
    networks: [tad]
    configs:
      - source: frpc_toml
        target: /etc/frp/frpc.toml
    deploy:
      <<: *deploy-any
      resources: *res-small

configs:
  frpc_toml:
    file: ${FRPC_FILE}
    name: tad_frpc_${FRPC_CONFIG_VERSION}

networks:
  tad:
    driver: overlay
    attachable: true
    name: ${NETWORK}
  # External overlay owned by your Traefik stack — HTTP ingress.
  traefik-net:
    external: true
    name: ${TRAEFIK_NET}
STACK

  ok "Swarm stack file generated"
}

# ── Swarm task helpers & lifecycle ────────────────────────────────────────────

# Container id of a running task for ${STACK}_<svc> on THIS node.
_local_task() {
  docker ps -q \
    -f "label=com.docker.swarm.service.name=${STACK}_$1" \
    -f "status=running" 2>/dev/null | head -n1
}

stack_deploy() {
  log "Deploying stack '${STACK}' (Swarm pulls images automatically)..."
  # Export .env so docker stack deploy can interpolate \${VAR} in the stack file.
  set -a; source "${ENV_FILE}" 2>/dev/null || true; set +a
  run "docker stack deploy --with-registry-auth --resolve-image always -c '${STACK_FILE}' ${STACK}"
  ok "Stack deployed (services converging — this can take a minute)"
}

wait_for_db() {
  local root_pass="${MYSQL_ROOT_PASSWORD:-}"
  if [[ -z "$root_pass" ]]; then
    set -a; source "${ENV_FILE}" 2>/dev/null || true; set +a
    root_pass="${MYSQL_ROOT_PASSWORD:-}"
  fi

  $DRY_RUN && { echo "  [dry] Would wait for MySQL"; return 0; }

  log "Waiting for MySQL to be ready..."
  local attempts=0
  # Run a throwaway client attached to the overlay network — works no matter
  # which node mysql was scheduled onto.
  until docker run --rm --network "${NETWORK}" "mysql:${MYSQL_VERSION}" \
      mysqladmin ping -h mysql -u root -p"${root_pass}" --silent &>/dev/null; do
    attempts=$((attempts + 1))
    [[ $attempts -ge 30 ]] && { err "MySQL did not become ready within 5 minutes."; exit 1; }
    printf "." >/dev/tty
    sleep 10
  done
  echo "" >/dev/tty
  ok "MySQL ready"
}

wait_for_app() {
  $DRY_RUN && { echo "  [dry] Would wait for cron (migration runner) task"; return 0; }

  log "Waiting for the migration runner (cron) task on this node..."
  local attempts=0 cid=""
  while true; do
    cid="$(_local_task cron)"
    if [[ -n "$cid" ]] && docker exec "$cid" php artisan --version &>/dev/null; then
      break
    fi
    attempts=$((attempts + 1))
    [[ $attempts -ge 30 ]] && { err "cron task did not become ready within 5 minutes."; exit 1; }
    printf "." >/dev/tty
    sleep 10
  done
  echo "" >/dev/tty
  ok "Migration runner ready"
}

run_seed() {
  $DRY_RUN && { echo "  [dry] Would run migrate + db:seed via the cron task"; return 0; }
  local cid; cid="$(_local_task cron)"
  [[ -z "$cid" ]] && { err "No running cron task found on this node for migrations."; exit 1; }

  log "Running migrations..."
  run "docker exec -w /var/www/html '${cid}' php artisan migrate --force"
  ok "Migrations complete"

  log "Seeding database (device types, OAuth clients, admin user, sample data)..."
  run "docker exec -w /var/www/html '${cid}' php artisan db:seed --force"
  ok "Database seeded — OAuth clients created with static IDs"
}

# ── Status display ────────────────────────────────────────────────────────────
show_status() {
  set -a; source "${ENV_FILE}" 2>/dev/null || true; set +a

  echo ""
  echo -e "${BOLD}── Swarm services ──────────────────────────────────────────────${RESET}"
  if ! $DRY_RUN; then
    docker stack services "${STACK}" \
      --format "table {{.Name}}\t{{.Mode}}\t{{.Replicas}}\t{{.Image}}" 2>/dev/null || true
  fi
  echo ""
  echo -e "${BOLD}── Versions ────────────────────────────────────────────────────${RESET}"
  echo "  server-login:    ${TAD_SERVER_LOGIN_TAG}"
  echo "  server-admin:    ${TAD_SERVER_ADMIN_TAG}"
  echo "  server-api:      ${TAD_SERVER_API_TAG}"
  echo "  server-graphql:  ${TAD_SERVER_GRAPHQL_TAG}"
  echo "  jt808:           ${TAD_JT808_TAG}"
  echo "  gt06:            ${TAD_GT06_TAG}"
  echo "  h02:             ${TAD_H02_TAG}"
  echo ""
  local shd="${SWARM_HOST_DOMAIN:-host-swarm.net}"
  echo -e "${BOLD}── Access (routed by your Traefik on ${TRAEFIK_NET}) ─────────────${RESET}"
  echo "  Login (SSO):  https://${LOGIN_DOMAIN:-login.track-any-device.com}   | https://login-tad.${shd}"
  echo "  Admin panel:  https://${ADMIN_DOMAIN:-admin.track-any-device.com}   | https://admin-tad.${shd}"
  echo "  GraphQL:      https://${GRAPHQL_DOMAIN:-graphql.track-any-device.com} | https://graphql-tad.${shd}"
  echo "  REST API:     https://api.${APP_DOMAIN:-track-any-device.com}     | https://api-tad.${shd}"
  echo "  Realtime WS:  https://ws.${APP_DOMAIN:-track-any-device.com}      | https://ws-tad.${shd}"
  echo "  phpMyAdmin:   http://<node-ip>:3333"
  echo "  MailPit:      http://<node-ip>:8025"
  echo ""
  local jt808_host="${JT808_HOST:-${APP_DOMAIN:-<your-domain>}}"
  echo -e "${BOLD}── Protocol Gateway Endpoints ──────────────────────────────────${RESET}"
  echo "    JT808: ${jt808_host}:${JT808_PORT:-7018}  (TCP, published via frp)"
  echo "    GT06:  ${GT06_HOST:-${APP_DOMAIN:-<your-domain>}}:${GT06_PORT:-7019}  (TCP)"
  echo "    H02:   ${H02_HOST:-${APP_DOMAIN:-<your-domain>}}:${H02_TCP_PORT:-7020}(TCP)/${H02_UDP_PORT:-7021}(UDP)"
  echo "  JT808 metrics: http://<node-ip>:9090/metrics"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════╗"
  echo -e "║   Track Any Device — Docker SWARM deployer (stack: ${STACK})            ║"
  echo -e "╚══════════════════════════════════════════════════════════════════╝${RESET}"

  check_prerequisites
  fetch_versions
  ensure_swarm

  if $UPDATE_ONLY; then
    set -a; source "${ENV_FILE}" 2>/dev/null || true; set +a
    patch_env
    set -a; source "${ENV_FILE}" 2>/dev/null || true; set +a
    write_frpc_config
    generate_stack
    stack_deploy
    wait_for_app
    log "Applying pending migrations..."
    run "docker exec -w /var/www/html \"\$(_local_task cron)\" php artisan migrate --force"
    ok "Migrations up to date."
    show_status
    ok "Update complete."
  else
    detect_existing_env
    collect_config
    create_directories
    write_env
    write_frpc_config
    generate_stack
    stack_deploy
    wait_for_db
    wait_for_app
    run_seed
    show_status

    echo -e "${BOLD}${GREEN}"
    echo "  ✓ Swarm deployment complete!"
    echo -e "${RESET}"
    echo "  Next steps:"
    echo "    1. Ensure your Traefik is attached to the '${TRAEFIK_NET}' network so it"
    echo "       can route the tad-* routers (login/admin/api/graphql/ws)."
    echo "    2. Point DNS (real domains + *-tad.${CFG_SWARM_HOST_DOMAIN:-host-swarm.net})"
    echo "       at the node(s) where your Traefik publishes :443."
    echo "    3. Add worker nodes with the 'docker swarm join' command shown above."
    echo "    4. Configure your frps server to accept the JT808 proxy (token must match)."
    echo "    5. Open the admin panel → approve your first tenant."
    echo ""
    echo "  Config saved to: ${ENV_FILE}"
    echo "  Stack file:      ${STACK_FILE}"
    echo "  Update later:    bash ${INSTALL_DIR}/tad.sh --update"
    echo ""
  fi
}

# Persist a copy of this script into track-any-device/ so future --update works.
# When invoked via `curl -fsSL .../tad.sh | bash` there is no local file, so the
# script is downloaded from the repo instead.
TAD_SH_URL="https://raw.githubusercontent.com/track-any-device/.github/main/tad.sh"
_persist_script() {
  ! $DRY_RUN && ! $UPDATE_ONLY || return 0
  mkdir -p "${INSTALL_DIR}" 2>/dev/null || true

  if [[ -n "$SCRIPT_SELF" && "$SCRIPT_SELF" != "${INSTALL_DIR}/tad.sh" ]]; then
    # Running as a regular file — copy it.
    cp "$SCRIPT_SELF" "${INSTALL_DIR}/tad.sh" 2>/dev/null \
      && chmod +x "${INSTALL_DIR}/tad.sh" || true
  elif [[ -z "$SCRIPT_SELF" ]]; then
    # Running via curl | bash — download a copy from the repo.
    curl -fsSL --max-time 15 "${TAD_SH_URL}" \
      -o "${INSTALL_DIR}/tad.sh" 2>/dev/null \
      && chmod +x "${INSTALL_DIR}/tad.sh" || true
  fi
}

_persist_script
main "$@"
