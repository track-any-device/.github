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
#         volumes/{mysql,influxdb,app_storage}   (local bind mounts)
#
# Ingress:
#   HTTP services (api, soketi) are routed by your EXISTING Traefik instance
#   over the external `traefik-net` overlay, using deploy labels
#   (traefik.swarm.network=traefik-net, tls=true, dual Host rules).
#   This stack does NOT run its own Traefik and does NOT manage TLS certs.
#
#   Device protocol servers (jt808/gt06/h02) are published DIRECTLY as Swarm
#   ports on the host — no frp/Cloudflare tunnel or relay. Open the matching
#   TCP/UDP ports in your firewall (see Step 3/4 below).
#
# Topology (deploys onto your EXISTING multi-node Swarm):
#   • Your Swarm, your `traefik-net`, and your node labels must already exist —
#     this script does NOT init a swarm, create networks, or label nodes.
#   • Run it on a MANAGER node (so it can `docker stack deploy`).
#   • Pinned services (mysql, influxdb, cron) require ONE node
#     labelled tad.storage=true — local bind volumes live there. Label it once:
#       docker node update --label-add tad.storage=true <node>
#   • Stateless services (api, queue, protocol servers, soketi …) run
#     on any node and reach the database/redis over the overlay network.
# ──────────────────────────────────────────────────────────────────────────────

# Capture script path BEFORE set -u (undefined when piped via curl | bash).
SCRIPT_SELF="${BASH_SOURCE[0]:-}"

set -euo pipefail

# ── Offline fallback versions ─────────────────────────────────────────────────
# The script fetches real latest release tags from GitHub at runtime; these are
# only used when GitHub is unreachable.
# VERSIONS_START
TAD_SERVER_API_TAG="v0.1.424-ac19c5e0"
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
# Note: TLS/ingress is handled by your EXISTING Traefik on the external
# `traefik-net` overlay — this stack does NOT ship its own Traefik.
# Device protocol ports are published directly by Swarm — no frp/tunnel relay.


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
  local api tenant web jt808 gt06 h02

  api=$(     _gh_latest "app")
  tenant=$(  _gh_latest "server-tenant")
  web=$(     _gh_latest "web")
  jt808=$(   _gh_latest "server-jt808")
  gt06=$(    _gh_latest "server-gt06")
  h02=$(     _gh_latest "server-h02")

  [[ -n "$api"     ]] && TAD_SERVER_API_TAG="$api"         || warn "server-api:     using fallback ${TAD_SERVER_API_TAG}"
  [[ -n "$tenant"  ]] && TAD_SERVER_TENANT_TAG="$tenant"
  [[ -n "$web"     ]] && TAD_SERVER_WEB_TAG="$web"
  [[ -n "$jt808"   ]] && TAD_JT808_TAG="$jt808"
  [[ -n "$gt06"    ]] && TAD_GT06_TAG="$gt06"
  [[ -n "$h02"     ]] && TAD_H02_TAG="$h02"

  echo ""
  echo -e "${BOLD}── Resolved versions ───────────────────────────────────────────${RESET}"
  printf "  %-18s %s\n" "server-api:"      "${TAD_SERVER_API_TAG}"
  printf "  %-18s %s\n" "server-tenant:"   "${TAD_SERVER_TENANT_TAG}"
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

  # Optional: prefer IPv4 so Docker can reach IPv6-only registries (quay.io) on
  # IPv4-only hosts. Needs root; skip silently (and report nothing) if we can't
  # write it — it is only a pull optimisation, never required.
  if [[ -f /etc/gai.conf && -w /etc/gai.conf ]] \
     && ! grep -q "^precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null; then
    if printf 'precedence ::ffff:0:0/96  100\n' >> /etc/gai.conf 2>/dev/null; then
      ok "IPv4 preference set in /etc/gai.conf (helps quay.io pulls on IPv4-only hosts)"
    fi
  fi
}

# ── Ensure this host is a Swarm manager + labelled as storage node ────────────
check_swarm() {
  log "Verifying the Swarm (read-only — nothing is created or modified)..."

  if $DRY_RUN; then
    echo "  [dry] Would verify Swarm is active + on a manager (no init, no changes)"
    return 0
  fi

  # We do NOT initialise a swarm — your cluster already exists. These are
  # advisory only: never fatal. `docker stack deploy` is the real authority.
  local state ctrl
  state=$(docker info --format '{{.Swarm.LocalState}}' 2>/dev/null || echo "unknown")
  ctrl=$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null || echo "")
  if [[ "$state" == "active" && "$ctrl" == "true" ]]; then
    ok "Swarm active (manager)"
  elif [[ "$state" == "active" ]]; then
    warn "This node is a Swarm worker — 'docker stack deploy' must run on a MANAGER. Continuing."
  else
    warn "Swarm state reported as '${state}', not 'active'."
    warn "  If your Swarm IS up, this user likely can't reach the Docker daemon — try: sudo bash tad.sh"
    warn "  (the /etc/gai.conf permission error above is the same root cause: not running as root)."
    warn "  Continuing — 'docker stack deploy' will give the authoritative error if anything's wrong."
  fi

  # External ingress network is owned by your Traefik — check, never create.
  if docker network ls --format '{{.Name}}' 2>/dev/null | grep -qx "${TRAEFIK_NET}"; then
    ok "Ingress network '${TRAEFIK_NET}' present"
  else
    warn "Network '${TRAEFIK_NET}' not found — your Traefik stack should provide it."
    warn "  Create once if needed: docker network create --driver overlay --attachable ${TRAEFIK_NET}"
  fi

  # Pinned services need ONE node labelled tad.storage=true. We do not set it.
  local has_storage=""
  while read -r _n; do
    [[ "$(docker node inspect "$_n" --format '{{ index .Spec.Labels "tad.storage" }}' 2>/dev/null)" == "true" ]] \
      && { has_storage=1; break; }
  done < <(docker node ls -q 2>/dev/null)
  if [[ -n "$has_storage" ]]; then
    ok "Storage node label present (tad.storage=true)"
  else
    warn "No node is labelled tad.storage=true — mysql/influxdb/cron will stay Pending."
    warn "  Label your storage node once: docker node update --label-add tad.storage=true <node>"
  fi
}

# ── Detect and load an existing .env ─────────────────────────────────────────
detect_existing_env() {
  local env_file="${ENV_FILE}"
  [[ -f "$env_file" ]] || return 0

  log "Loading existing configuration from ${env_file}..."
  set -a; source "$env_file" 2>/dev/null || true; set +a

  CFG_DOMAIN="${APP_DOMAIN:-}"; CFG_DOMAIN="${CFG_DOMAIN#api.}"  # tolerate a stale APP_DOMAIN that already includes api.
  CFG_SCHEME="https"
  CFG_MYSQL_DB="${MYSQL_DATABASE:-tad}"
  CFG_MYSQL_USER="${MYSQL_USER:-tad}"
  CFG_MYSQL_ROOT_PASS="${MYSQL_ROOT_PASSWORD:-}"
  CFG_MYSQL_PASS="${MYSQL_PASSWORD:-}"
  CFG_SWARM_HOST_DOMAIN="${SWARM_HOST_DOMAIN:-host-swarm.net}"
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
  CFG_API_KEY="${API_APP_KEY:-}"
  CFG_PUSHER_ID="${PUSHER_APP_ID:-}"
  CFG_PUSHER_KEY="${PUSHER_APP_KEY:-}"
  CFG_PUSHER_SECRET="${PUSHER_APP_SECRET:-}"
  CFG_INFLUX_PASS="${INFLUXDB_PASSWORD:-}"
  CFG_INFLUX_TOKEN="${INFLUXDB_TOKEN:-}"
  CFG_PASSPORT_PRIVATE="${PASSPORT_PRIVATE_KEY_B64:-}"
  CFG_PASSPORT_PUBLIC="${PASSPORT_PUBLIC_KEY_B64:-}"
  # ── Public current-state tracker (server-tenant) ──
  CFG_TRACKER_HOST="${TRACKER_HOST:-}"
  CFG_TENANT_APP_KEY="${TENANT_APP_KEY:-}"
  CFG_APP_TENANT_ID="${APP_TENANT_ID:-}"
  CFG_APP_TENANT_SLUG="${APP_TENANT_SLUG:-}"
  CFG_TENANT_API_TOKEN="${TENANT_API_TOKEN:-}"
  CFG_GOOGLE_MAPS_API_KEY="${GOOGLE_MAPS_API_KEY:-}"

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
    echo "  SMS URL:     ${CFG_SMS_URL:-(not configured)}"
    echo ""
    [[ -z "${CFG_API_KEY:-}"       ]] && CFG_API_KEY=$(gen_app_key)     && ok "API app key (generated)"
    [[ -z "${CFG_TENANT_APP_KEY:-}" ]] && CFG_TENANT_APP_KEY=$(gen_app_key) && ok "Public tracker app key (generated)"
    [[ -z "${CFG_TRACKER_HOST:-}"  ]] && CFG_TRACKER_HOST="track.${CFG_DOMAIN}"
    [[ -z "${CFG_PUSHER_ID:-}"     ]] && CFG_PUSHER_ID=$(gen_pusher_id)
    [[ -z "${CFG_PUSHER_KEY:-}"    ]] && CFG_PUSHER_KEY=$(gen_hex)
    [[ -z "${CFG_PUSHER_SECRET:-}" ]] && CFG_PUSHER_SECRET=$(gen_hex)
    [[ -z "${CFG_INFLUX_PASS:-}"   ]] && CFG_INFLUX_PASS=$(gen_password)
    [[ -z "${CFG_INFLUX_TOKEN:-}"  ]] && CFG_INFLUX_TOKEN=$(gen_hex)
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
  # The API host is derived as api.${CFG_DOMAIN}; strip a leading "api." the user may have typed
  # (e.g. api.track-any-device.com → track-any-device.com) so APP_URL never doubles to api.api.*.
  CFG_DOMAIN="${CFG_DOMAIN#api.}"
  CFG_SCHEME="https"
  CFG_SWARM_HOST_DOMAIN=$(ask "Swarm host domain (for *-tad.<domain> router hostnames)" "host-swarm.net")

  echo ""
  dim "  Your existing Traefik (on external network '${TRAEFIK_NET}') will route,"
  dim "  with TLS (tls=true), each service on BOTH a swarm-host name and the real domain:"
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
  echo -e "${BOLD}── Step 3/4 — Device protocol endpoints (direct ports) ─────────${RESET}"
  echo ""
  dim "  The device protocol servers are published DIRECTLY as Swarm ports on the"
  dim "  host (no frp/Cloudflare tunnel). Trackers connect straight to a node IP:"
  dim "    JT808: TCP 7018   GT06: TCP 7019   H02: TCP 7020 + UDP 7021"
  dim "  Open these ports in your host/cloud firewall so trackers can reach them."
  echo ""

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

  # ── Public current-state tracker (server-tenant) ──────────────────────────
  # Standalone public page; connects to the central api with the tenant's
  # machine ACCESS KEY (Tenant ID + tk_… key) generated/copied from /admin
  # organisations. Your Traefik routes Host(${TRACKER_HOST:-track.<domain>}) → :80.
  # Leave the ID/key blank to start; the tracker just won't sync until both set.
  echo ""
  dim "  Public current-state tracker (server-tenant) — optional:"
  CFG_TRACKER_HOST=$(ask "Public tracker hostname" "track.${CFG_DOMAIN}")
  CFG_APP_TENANT_ID=$(ask "Public tenant ID (from /admin organisations → the org's X-Tenant-Id)")
  CFG_TENANT_API_TOKEN=$(ask "Public tenant access key (tk_… — Authorization: Bearer from the org screen)")
  CFG_APP_TENANT_SLUG=$(ask "Public tenant slug (optional)")
  CFG_GOOGLE_MAPS_API_KEY=$(ask "Google Maps API key for the tracker map (blank to skip)")

  echo ""
  echo -e "${BOLD}── Step 4/4 — Generating secrets ───────────────────────────────${RESET}"
  echo ""
  CFG_API_KEY=$(gen_app_key);        ok "API app key"
  CFG_TENANT_APP_KEY=$(gen_app_key); ok "Public tracker app key"
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
  echo "  Device ports:       JT808 7018/tcp · GT06 7019/tcp · H02 7020/tcp + 7021/udp (direct)"
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
SESSION_DOMAIN=.${CFG_DOMAIN}
# Swarm host domain → Traefik router hostnames are <svc>-tad.<this>
SWARM_HOST_DOMAIN=${CFG_SWARM_HOST_DOMAIN}

# ── App encryption keys ───────────────────────────────────────────────────────
API_APP_KEY=${CFG_API_KEY}

# ── Public current-state tracker (server-tenant) ──────────────────────────────
# Standalone PUBLIC device tracker (image trackanydevice/server-tenant, SQLite).
# Routing: your Traefik routes Host(${CFG_TRACKER_HOST:-track.${CFG_DOMAIN}}) → :80.
#
# APP_TENANT_ID + TENANT_API_TOKEN are GENERATED/COPIED from the central admin
# org-details screen (/admin organisations → rotate via
# POST /api/admin/tenants/{id}/key). APP_TENANT_ID → X-Tenant-Id header;
# TENANT_API_TOKEN (tk_…) → Authorization: Bearer. There is no minting here.
# Leave the ID/token blank to start; the tracker just won't sync until both
# are filled in (edit this file, then redeploy: bash tad.sh --update).
TRACKER_HOST=${CFG_TRACKER_HOST:-track.${CFG_DOMAIN}}
TENANT_APP_KEY=${CFG_TENANT_APP_KEY}
APP_TENANT_ID=${CFG_APP_TENANT_ID:-}
APP_TENANT_SLUG=${CFG_APP_TENANT_SLUG:-}
TENANT_API_TOKEN=${CFG_TENANT_API_TOKEN:-}
GOOGLE_MAPS_API_KEY=${CFG_GOOGLE_MAPS_API_KEY:-}

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
  _ensure_var "GT06_HOST"         ""
  _ensure_var "GT06_PORT"         "7019"
  _ensure_var "H02_HOST"          ""
  _ensure_var "H02_TCP_PORT"      "7020"
  _ensure_var "H02_UDP_PORT"      "7021"
  _ensure_var "SMS_GATEWAY_URL"   ""
  _ensure_var "SMS_GATEWAY_API_KEY" ""
  _ensure_var "SMS_MASTER_NUMBER" ""

  # ── Public current-state tracker (server-tenant) ──
  # Added for existing deploys. TRACKER_HOST defaults to track.<APP_DOMAIN>;
  # TENANT_APP_KEY is generated. APP_TENANT_ID/TENANT_API_TOKEN are left blank
  # for the operator to paste from /admin organisations — the tracker won't
  # sync until both are filled in.
  _ensure_var "TRACKER_HOST"      "track.${APP_DOMAIN:-track-any-device.com}"
  _ensure_var "TENANT_APP_KEY"    "$(gen_app_key)"
  _ensure_var "APP_TENANT_ID"     ""
  _ensure_var "APP_TENANT_SLUG"   ""
  _ensure_var "TENANT_API_TOKEN"  ""
  _ensure_var "GOOGLE_MAPS_API_KEY" ""

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
  run "mkdir -p '${INSTALL_DIR}/volumes/server_tenant_db'"
  if ! $DRY_RUN; then
    chmod -R 775 "${INSTALL_DIR}/volumes" 2>/dev/null || true
  fi
  ok "Directories ready"
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
# Versions:  api=${TAD_SERVER_API_TAG}
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

  # ── Central REST API Server ──────────────────────────────────────────────────
  api:
    image: ${ORG}/server-api:latest
    networks: [tad, traefik-net]
    environment:
      <<: *app-env
      APP_SURFACE: api
      APP_URL: https://api.\${APP_DOMAIN}
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
      resources: *res-app
      labels:
        - "traefik.enable=true"
        - "traefik.swarm.network=${TRAEFIK_NET}"
        - "traefik.http.services.tad-api.loadbalancer.server.port=80"
        - "traefik.http.routers.tad-api.rule=Host(\`api-tad.\${SWARM_HOST_DOMAIN}\`) || Host(\`api.\${APP_DOMAIN}\`)"
        - "traefik.http.routers.tad-api.entrypoints=websecure"
        - "traefik.http.routers.tad-api.tls=true"
        - "traefik.http.routers.tad-api.service=tad-api"

  # ── Public Current-State Tracker (server-tenant) ─────────────────────────────
  # Standalone PUBLIC device tracker (image trackanydevice/server-tenant, SQLite,
  # current-state only). Authenticates to the central api's /api/portal endpoints
  # with the tenant's machine ACCESS KEY: Authorization: Bearer \${TENANT_API_TOKEN}
  # + X-Tenant-Id: \${APP_TENANT_ID}. Generate/copy the Tenant ID + access key from
  # the admin org-details screen (/admin organisations → rotate via
  # POST /api/admin/tenants/{id}/key) — there is no minting here.
  #
  # ROUTING: your existing Traefik publishes it on Host(\`\${TRACKER_HOST}\`) → :80,
  # mirroring the api router's tls/entrypoint labels.
  #
  # SQLite persistence: pinned to the storage node with a local bind volume so the
  # current-state DB survives restarts. Runs migrate --force on boot (creating the
  # schema in an empty volume on first run) before starting supervisord
  # (nginx + php-fpm + tenant:listen-signals).
  server-tenant:
    image: ${ORG}/server-tenant:\${TAD_SERVER_TENANT_TAG:-latest}
    networks: [tad, traefik-net]
    command: >
      sh -c "php /var/www/html/artisan migrate --force &&
             exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf"
    environment:
      APP_ENV: production
      APP_KEY: \${TENANT_APP_KEY}
      APP_URL: https://\${TRACKER_HOST}
      APP_TENANT_ID:   \${APP_TENANT_ID}
      APP_TENANT_SLUG: \${APP_TENANT_SLUG:-}
      TENANT_API_TOKEN: \${TENANT_API_TOKEN}
      PLATFORM_API_URL: http://api
      DB_CONNECTION: sqlite
      BROADCAST_CONNECTION: pusher
      PUSHER_APP_KEY: \${PUSHER_APP_KEY}
      PUSHER_HOST:    soketi
      PUSHER_PORT:    6001
      PUSHER_SCHEME:  http
      PUSHER_APP_CLUSTER: mt1
      GOOGLE_MAPS_API_KEY: \${GOOGLE_MAPS_API_KEY:-}
      LOG_CHANNEL: stderr
    volumes:
      - ${INSTALL_DIR}/volumes/server_tenant_db:/var/www/html/database
    deploy:
      <<: *deploy-storage
      resources: *res-small
      labels:
        - "traefik.enable=true"
        - "traefik.swarm.network=${TRAEFIK_NET}"
        - "traefik.http.services.tad-tracker.loadbalancer.server.port=80"
        - "traefik.http.routers.tad-tracker.rule=Host(\`\${TRACKER_HOST}\`)"
        - "traefik.http.routers.tad-tracker.entrypoints=websecure"
        - "traefik.http.routers.tad-tracker.tls=true"
        - "traefik.http.routers.tad-tracker.service=tad-tracker"

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

  # ── JT808 GPS TCP Server (direct host-mode port — preserves device source IP) ─
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
  echo "  server-api:      ${TAD_SERVER_API_TAG}"
  echo "  server-tenant:   ${TAD_SERVER_TENANT_TAG}"
  echo "  jt808:           ${TAD_JT808_TAG}"
  echo "  gt06:            ${TAD_GT06_TAG}"
  echo "  h02:             ${TAD_H02_TAG}"
  echo ""
  local shd="${SWARM_HOST_DOMAIN:-host-swarm.net}"
  echo -e "${BOLD}── Access (routed by your Traefik on ${TRAEFIK_NET}) ─────────────${RESET}"
  echo "  REST API:     https://api.${APP_DOMAIN:-track-any-device.com}     | https://api-tad.${shd}"
  echo "  Realtime WS:  https://ws.${APP_DOMAIN:-track-any-device.com}      | https://ws-tad.${shd}"
  echo "  Public track: https://${TRACKER_HOST:-track.${APP_DOMAIN:-track-any-device.com}}  (server-tenant :80)"
  echo "  phpMyAdmin:   http://<node-ip>:3333"
  echo "  MailPit:      http://<node-ip>:8025"
  echo ""
  echo -e "${BOLD}── Public tracker (server-tenant) ──────────────────────────────${RESET}"
  echo "  Routed by your Traefik: Host(${TRACKER_HOST:-track.${APP_DOMAIN:-track-any-device.com}}) → :80"
  echo "  Point DNS for that host at your Traefik node(s)."
  if [[ -z "${APP_TENANT_ID:-}" || -z "${TENANT_API_TOKEN:-}" ]]; then
    warn "Tenant ID / access key not set — the tracker is deployed but will NOT"
    warn "  sync or connect yet. Paste both from /admin organisations (X-Tenant-Id"
    warn "  + tk_… access key) into ${ENV_FILE} (APP_TENANT_ID, TENANT_API_TOKEN),"
    warn "  then redeploy: bash tad.sh --update"
  else
    ok "Tenant ID + access key configured — the tracker will sync from the central API."
  fi
  echo ""
  local jt808_host="${JT808_HOST:-${APP_DOMAIN:-<your-domain>}}"
  echo -e "${BOLD}── Protocol Gateway Endpoints (direct Swarm ports) ─────────────${RESET}"
  echo "    JT808: ${jt808_host}:${JT808_PORT:-7018}  (TCP, host-published)"
  echo "    GT06:  ${GT06_HOST:-${APP_DOMAIN:-<your-domain>}}:${GT06_PORT:-7019}  (TCP, host-published)"
  echo "    H02:   ${H02_HOST:-${APP_DOMAIN:-<your-domain>}}:${H02_TCP_PORT:-7020}(TCP)/${H02_UDP_PORT:-7021}(UDP)  (host-published)"
  echo "  JT808 metrics: http://<node-ip>:9090/metrics"
  echo "  Open these device ports in your host/cloud firewall on the node(s) running each server."
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
  check_swarm

  if $UPDATE_ONLY; then
    set -a; source "${ENV_FILE}" 2>/dev/null || true; set +a
    patch_env
    set -a; source "${ENV_FILE}" 2>/dev/null || true; set +a
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
    echo "       can route the tad-* routers (api/ws/tracker)."
    echo "    2. Point DNS (real domains + *-tad.${CFG_SWARM_HOST_DOMAIN:-host-swarm.net}"
    echo "       + the public tracker ${CFG_TRACKER_HOST:-track.${CFG_DOMAIN}})"
    echo "       at the node(s) where your Traefik publishes :443."
    echo "       Public tracker: copy the Tenant ID (X-Tenant-Id) + access key (tk_…)"
    echo "       from /admin organisations into ${ENV_FILE}"
    echo "       (APP_TENANT_ID, TENANT_API_TOKEN), then: bash tad.sh --update"
    echo "    3. Add worker nodes with the 'docker swarm join' command shown above."
    echo "    4. Open the device protocol ports in your host/cloud firewall so trackers"
    echo "       can reach them directly: 7018/tcp (JT808), 7019/tcp (GT06),"
    echo "       7020/tcp + 7021/udp (H02)."
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
