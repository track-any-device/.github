#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Track Any Device — Platform Installer / Updater
#
# Fresh install (interactive, auto-generates all secrets):
#   bash install.sh
#   — or —
#   curl -fsSL https://raw.githubusercontent.com/track-any-device/.github/main/install.sh | bash
#
# Update to latest pinned versions (silent, no prompts):
#   bash install.sh --update
#
# Options:
#   --update      Pull new images + restart changed services. No prompts.
#   --dir PATH    Override install directory (default: ~/tad or $TAD_DIR)
#   --dry-run     Print what would happen without making changes
# ──────────────────────────────────────────────────────────────────────────────

# Capture script path BEFORE set -u activates.
# BASH_SOURCE[0] is undefined when the script is piped via curl | bash
# (stdin). Reading it after set -u causes "unbound variable". Capture it
# now while the default is still permissive, then enable strict mode.
SCRIPT_SELF="${BASH_SOURCE[0]:-}"

set -euo pipefail

# ── Offline fallback versions ─────────────────────────────────────────────────
# The script ALWAYS fetches the real latest release tags from GitHub at runtime.
# These values are only used when GitHub is unreachable (no internet / rate limit).
# VERSIONS_START
TAD_SERVER_LOGIN_TAG="v0.4.3"
TAD_SERVER_ADMIN_TAG="v0.0.9"
TAD_SERVER_API_TAG="v0.1.424-ac19c5e0"
TAD_SERVER_GRAPHQL_TAG="v0.0.7"
TAD_SERVER_TENANT_TAG="latest"
TAD_SERVER_WEB_TAG="latest"
TAD_JT808_TAG="0.1.1"
TAD_P901_TAG="0.1.1"
# VERSIONS_END

# Third-party pinned versions (upgrade intentionally)
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

# ── Static OAuth client credentials (seeded automatically by db:seed) ─────────
# These match OAuthClientSeeder in package-sso-server.
# Web and mobile apps embed these as defaults — no configuration needed.
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
INSTALL_DIR="${TAD_DIR:-$HOME/tad}"
ORG="trackanydevice"
DRY_RUN=false
UPDATE_ONLY=false
HAVE_EXISTING_ENV=false   # set to true when an existing .env is found and loaded

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

# ── Dynamic version resolution ────────────────────────────────────────────────
# Fetches the latest release tag from each service's GitHub repository.
# Falls back silently to the hardcoded offline values above if GitHub is
# unreachable (no internet, rate-limited, or repo has no releases yet).

_gh_latest() {
  local repo="$1"
  # Try GitHub API — 5-second timeout so a slow network doesn't hang the script
  local tag
  tag=$(curl -fsSL --max-time 5 \
    "https://api.github.com/repos/track-any-device/${repo}/releases/latest" \
    2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('tag_name',''))" \
    2>/dev/null || true)
  echo "$tag"
}

fetch_versions() {
  log "Fetching latest release versions from GitHub..."

  local login admin api graphql tenant web jt808

  login=$(  _gh_latest "server-login")
  admin=$(   _gh_latest "server-admin")
  api=$(     _gh_latest "app")
  graphql=$( _gh_latest "server-graphql")
  tenant=$(  _gh_latest "server-tenant")
  web=$(     _gh_latest "web")
  jt808=$(   _gh_latest "server-jt808")

  # Apply resolved tags, falling back to the offline defaults for any empty result
  [[ -n "$login"   ]] && TAD_SERVER_LOGIN_TAG="$login"     || warn "server-login:   using fallback ${TAD_SERVER_LOGIN_TAG}"
  [[ -n "$admin"   ]] && TAD_SERVER_ADMIN_TAG="$admin"     || warn "server-admin:   using fallback ${TAD_SERVER_ADMIN_TAG}"
  [[ -n "$api"     ]] && TAD_SERVER_API_TAG="$api"         || warn "server-api:     using fallback ${TAD_SERVER_API_TAG}"
  [[ -n "$graphql" ]] && TAD_SERVER_GRAPHQL_TAG="$graphql" || warn "server-graphql: using fallback ${TAD_SERVER_GRAPHQL_TAG}"
  [[ -n "$tenant"  ]] && TAD_SERVER_TENANT_TAG="$tenant"   # stays 'latest' if no release
  [[ -n "$web"     ]] && TAD_SERVER_WEB_TAG="$web"         # stays 'latest' if no release
  [[ -n "$jt808"   ]] && TAD_JT808_TAG="$jt808" && TAD_P901_TAG="$jt808"

  echo ""
  echo -e "${BOLD}── Resolved versions ───────────────────────────────────────────${RESET}"
  printf "  %-18s %s\n" "server-login:"    "${TAD_SERVER_LOGIN_TAG}"
  printf "  %-18s %s\n" "server-admin:"    "${TAD_SERVER_ADMIN_TAG}"
  printf "  %-18s %s\n" "server-api:"      "${TAD_SERVER_API_TAG}"
  printf "  %-18s %s\n" "server-graphql:"  "${TAD_SERVER_GRAPHQL_TAG}"
  printf "  %-18s %s\n" "server-tenant:"   "${TAD_SERVER_TENANT_TAG}"
  printf "  %-18s %s\n" "jt808-server:"    "${TAD_JT808_TAG}"
  printf "  %-18s %s\n" "web (Pages):"     "Cloudflare Pages → ${TAD_SERVER_WEB_TAG}"
  echo ""
}

# ── Helpers ───────────────────────────────────────────────────────────────────

# Read user input from /dev/tty so curl | bash works (stdin is the pipe)
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

  if ! docker compose version &>/dev/null; then
    err "Docker Compose v2 required. Install: https://docs.docker.com/compose/install/"
    exit 1
  fi

  ok "Docker $(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)"
  ok "Docker Compose $(docker compose version --short)"

  # ── Ensure Docker can reach IPv6-only registries (e.g. quay.io) ─────────────
  # On hosts without native IPv6, glibc may resolve quay.io to an IPv6 address
  # that is unreachable, causing "network is unreachable" during docker pull.
  # Force the kernel to prefer IPv4 for all outgoing connections.
  if [[ -f /etc/gai.conf ]] && ! grep -q "^precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null; then
    echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf 2>/dev/null || true
    ok "IPv4 preference set in /etc/gai.conf (fixes quay.io pull on IPv4-only hosts)"
  fi
}

# ── Detect and load an existing .env ─────────────────────────────────────────
# If INSTALL_DIR already contains a .env, back the whole directory up to ~/tadx,
# then source it into CFG_* variables so collect_config can skip all prompts and
# write_env can produce an identical .env on the fresh install.
detect_existing_env() {
  local env_file="${INSTALL_DIR}/.env"
  [[ -f "$env_file" ]] || return 0

  local backup_dir="${HOME}/tadx"
  warn "Existing install found at ${INSTALL_DIR}"
  log "Backing up ${INSTALL_DIR} → ${backup_dir}..."
  rm -rf "${backup_dir}" 2>/dev/null || true
  cp -r "${INSTALL_DIR}" "${backup_dir}"
  ok "Backup saved → ${backup_dir}"

  log "Loading existing configuration..."
  set -a; source "$env_file" 2>/dev/null || true; set +a

  # Map every env var back to the CFG_* names collect_config would have set
  CFG_DOMAIN="${APP_DOMAIN:-}"
  CFG_SCHEME="https"
  CFG_LOGIN_DOMAIN="${LOGIN_DOMAIN:-login.${CFG_DOMAIN}}"
  CFG_ADMIN_DOMAIN="${ADMIN_DOMAIN:-admin.${CFG_DOMAIN}}"
  CFG_GRAPHQL_DOMAIN="${GRAPHQL_DOMAIN:-graphql.${CFG_DOMAIN}}"
  CFG_MYSQL_DB="${MYSQL_DATABASE:-tad}"
  CFG_MYSQL_USER="${MYSQL_USER:-tad}"
  CFG_MYSQL_ROOT_PASS="${MYSQL_ROOT_PASSWORD:-}"
  CFG_MYSQL_PASS="${MYSQL_PASSWORD:-}"
  CFG_CF_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}"
  CFG_JT808_HOST="${JT808_HOST:-}"
  CFG_JT808_PORT="${JT808_PORT:-7018}"
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
  # ── Reuse existing config (no prompts) ──────────────────────────────────────
  if $HAVE_EXISTING_ENV; then
    echo ""
    echo -e "${BOLD}── Reusing existing configuration ──────────────────────────────${RESET}"
    echo ""
    echo "  Domain:    ${CFG_DOMAIN}"
    echo "  Database:  ${CFG_MYSQL_USER}@mysql/${CFG_MYSQL_DB}"
    echo "  CF Tunnel: ${CFG_CF_TOKEN:-(not configured)}"
    echo "  SMS URL:   ${CFG_SMS_URL:-(not configured)}"
    echo "  JT808:     ${CFG_JT808_HOST:-${CFG_DOMAIN}}:${CFG_JT808_PORT}"
    echo ""
    dim "  All secrets (app keys, DB passwords, Passport RSA keys) preserved."
    echo ""
    # Generate only secrets that are missing from the old .env
    [[ -z "${CFG_LOGIN_KEY:-}"       ]] && CFG_LOGIN_KEY=$(gen_app_key)   && ok "Login app key (generated)"
    [[ -z "${CFG_ADMIN_KEY:-}"       ]] && CFG_ADMIN_KEY=$(gen_app_key)   && ok "Admin app key (generated)"
    [[ -z "${CFG_API_KEY:-}"         ]] && CFG_API_KEY=$(gen_app_key)     && ok "API app key (generated)"
    [[ -z "${CFG_GRAPHQL_KEY:-}"     ]] && CFG_GRAPHQL_KEY=$(gen_app_key) && ok "GraphQL app key (generated)"
    [[ -z "${CFG_PUSHER_ID:-}"       ]] && CFG_PUSHER_ID=$(gen_pusher_id)
    [[ -z "${CFG_PUSHER_KEY:-}"      ]] && CFG_PUSHER_KEY=$(gen_hex)
    [[ -z "${CFG_PUSHER_SECRET:-}"   ]] && CFG_PUSHER_SECRET=$(gen_hex)
    [[ -z "${CFG_INFLUX_PASS:-}"     ]] && CFG_INFLUX_PASS=$(gen_password)
    [[ -z "${CFG_INFLUX_TOKEN:-}"    ]] && CFG_INFLUX_TOKEN=$(gen_hex)
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

  # ── Fresh interactive prompts ────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}── Step 1/4 — Domain ───────────────────────────────────────────${RESET}"
  echo ""

  CFG_DOMAIN=$(ask "Main domain" "track-any-device.com")
  CFG_SCHEME="https"

  # Derive subdomains
  CFG_LOGIN_DOMAIN="login.${CFG_DOMAIN}"
  CFG_ADMIN_DOMAIN="admin.${CFG_DOMAIN}"
  CFG_GRAPHQL_DOMAIN="graphql.${CFG_DOMAIN}"

  echo ""
  dim "  Subdomains derived:"
  dim "    Login:   ${CFG_LOGIN_DOMAIN}"
  dim "    Admin:   ${CFG_ADMIN_DOMAIN}"
  dim "    GraphQL: ${CFG_GRAPHQL_DOMAIN}"
  dim "    API:     api.${CFG_DOMAIN}"
  dim "    Web/My:  ${CFG_DOMAIN}/my"
  echo ""

  echo -e "${BOLD}── Step 2/4 — Database ─────────────────────────────────────────${RESET}"
  echo ""

  CFG_MYSQL_DB=$(ask "Database name" "tad")
  CFG_MYSQL_USER=$(ask "Database user" "tad")

  # Auto-generate passwords (user can override but rarely needs to)
  local root_input
  root_input=$(ask_secret "MySQL root password (blank to auto-generate)")
  CFG_MYSQL_ROOT_PASS="${root_input:-$(gen_password)}"

  local pass_input
  pass_input=$(ask_secret "MySQL user password (blank to auto-generate)")
  CFG_MYSQL_PASS="${pass_input:-$(gen_password)}"

  ok "Database: ${CFG_MYSQL_USER}@mysql/${CFG_MYSQL_DB}"

  echo ""
  echo -e "${BOLD}── Step 3/4 — Optional Services ────────────────────────────────${RESET}"
  echo ""

  CFG_CF_TOKEN=$(ask "Cloudflare Tunnel token (blank to skip)")

  # JT808 device configuration (written into the setup SMS sent to the device)
  # When a GPS tracker is added, the platform sends it an SMS containing the
  # JT808 host and port so the device firmware knows where to stream data.
  # Leave host blank → defaults to APP_DOMAIN. Only override if JT808 is
  # on a different IP (e.g. a frp VPS with a dedicated public IP).
  CFG_JT808_HOST=$(ask "JT808 host to send in device setup SMS (blank = use APP_DOMAIN)")
  CFG_JT808_PORT=$(ask "JT808 port to send in device setup SMS" "7018")

  CFG_SMS_URL=$(ask   "SMS Gateway URL (blank to skip)")
  CFG_SMS_KEY=""
  CFG_SMS_NUMBER=""
  if [[ -n "${CFG_SMS_URL}" ]]; then
    CFG_SMS_KEY=$(ask "SMS Gateway API key")
    CFG_SMS_NUMBER=$(ask "SMS master number (e.g. +92300000000)")
  fi

  echo ""
  echo -e "${BOLD}── Step 4/4 — Generating secrets ───────────────────────────────${RESET}"
  echo ""

  # App encryption keys
  CFG_LOGIN_KEY=$(gen_app_key);   ok "Login app key"
  CFG_ADMIN_KEY=$(gen_app_key);   ok "Admin app key"
  CFG_API_KEY=$(gen_app_key);     ok "API app key"
  CFG_GRAPHQL_KEY=$(gen_app_key); ok "GraphQL app key"

  # Pusher / Soketi
  CFG_PUSHER_ID=$(gen_pusher_id)
  CFG_PUSHER_KEY=$(gen_hex)
  CFG_PUSHER_SECRET=$(gen_hex)
  ok "Pusher credentials  (ID: ${CFG_PUSHER_ID})"

  # InfluxDB
  CFG_INFLUX_PASS=$(gen_password)
  CFG_INFLUX_TOKEN=$(gen_hex)
  ok "InfluxDB credentials"

  # Passport RSA keys (4096-bit, takes ~5-10 seconds)
  echo -ne "  Generating Passport RSA keys (4096-bit)..." >/dev/tty
  local priv_pem
  priv_pem=$(openssl genrsa 4096 2>/dev/null)
  CFG_PASSPORT_PRIVATE=$(echo "$priv_pem" | openssl base64 -A)
  CFG_PASSPORT_PUBLIC=$(echo "$priv_pem" | openssl rsa -pubout 2>/dev/null | openssl base64 -A)
  echo " done" >/dev/tty
  ok "Passport RSA key pair"

  echo ""
  ok "OAuth clients (pre-seeded, no action needed):"
  dim "    Web portal:    ${WEB_CLIENT_ID} / ${WEB_CLIENT_SECRET}"
  dim "    Admin panel:   ${ADMIN_CLIENT_ID} / ${ADMIN_CLIENT_SECRET}"
  dim "    GraphQL:       ${GRAPHQL_CLIENT_ID} / ${GRAPHQL_CLIENT_SECRET}"
  dim "    Mobile (PKCE): ${MOBILE_CLIENT_ID} (no secret)"
  echo ""

  # Final confirmation
  echo -e "${BOLD}── Configuration summary ───────────────────────────────────────${RESET}"
  echo ""
  echo "  Install directory:  ${INSTALL_DIR}"
  echo "  Domain:             ${CFG_DOMAIN}"
  echo "  Database:           ${CFG_MYSQL_USER}@mysql/${CFG_MYSQL_DB}"
  echo "  Cloudflare Tunnel:  ${CFG_CF_TOKEN:-(skipped)}"
  echo "  SMS Gateway:        ${CFG_SMS_URL:-(skipped)}"
  echo ""

  if ! confirm "Proceed with installation?"; then
    echo "Aborted."
    exit 0
  fi
}

# ── Write fully-populated .env ─────────────────────────────────────────────────
write_env() {
  local env_file="${INSTALL_DIR}/.env"

  # If .env already exists AND we haven't loaded it (shouldn't happen in normal
  # flow, but guard against accidental overwrites just in case).
  if [[ -f "$env_file" ]] && ! $HAVE_EXISTING_ENV; then
    warn ".env already exists — skipping. Delete it to reconfigure, or edit directly."
    # Source it so wait_for_db can read MYSQL_ROOT_PASSWORD
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
# Track Any Device — Platform Environment
# Generated by install.sh on $(date -u +"%Y-%m-%d %H:%M UTC")
# ──────────────────────────────────────────────────────────────────────────────

# ── Domain ────────────────────────────────────────────────────────────────────
APP_DOMAIN=${CFG_DOMAIN}
LOGIN_DOMAIN=${CFG_LOGIN_DOMAIN}
ADMIN_DOMAIN=${CFG_ADMIN_DOMAIN}
GRAPHQL_DOMAIN=${CFG_GRAPHQL_DOMAIN}
SESSION_DOMAIN=.${CFG_DOMAIN}

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
# Generated at install time. Do not lose these — Passport tokens are signed
# with the private key and verified with the public key.
# To rotate: generate new keys and restart login + api + graphql + admin.
PASSPORT_PRIVATE_KEY_B64=${CFG_PASSPORT_PRIVATE}
PASSPORT_PUBLIC_KEY_B64=${CFG_PASSPORT_PUBLIC}

# ── Static OAuth clients (seeded automatically by php artisan db:seed) ────────
# These are baked into the web and mobile apps as default values.
# No additional configuration needed for web portal or mobile app.
# To rotate for production: update these values, delete the oauth_clients rows,
# and re-run php artisan db:seed.
WEB_SSO_CLIENT_ID=${WEB_CLIENT_ID}
WEB_SSO_CLIENT_SECRET=${WEB_CLIENT_SECRET}
MY_SSO_CLIENT_ID=${MY_CLIENT_ID}
MY_SSO_CLIENT_SECRET=${MY_CLIENT_SECRET}
ADMIN_SSO_CLIENT_ID=${ADMIN_CLIENT_ID}
ADMIN_SSO_CLIENT_SECRET=${ADMIN_CLIENT_SECRET}
GRAPHQL_SSO_CLIENT_ID=${GRAPHQL_CLIENT_ID}
GRAPHQL_SSO_CLIENT_SECRET=${GRAPHQL_CLIENT_SECRET}
MOBILE_CLIENT_ID=${MOBILE_CLIENT_ID}
# Mobile uses PKCE — no client secret stored

# ── Cloudflare Tunnel ─────────────────────────────────────────────────────────
# Configure public hostnames in Zero Trust → Networks → Tunnels.
CLOUDFLARE_TUNNEL_TOKEN=${CFG_CF_TOKEN:-}

# ── SMS Gateway (optional) ────────────────────────────────────────────────────
SMS_GATEWAY_URL=${CFG_SMS_URL:-}
SMS_GATEWAY_API_KEY=${CFG_SMS_KEY:-}
SMS_MASTER_NUMBER=${CFG_SMS_NUMBER:-}

# ── JT808 device configuration (embedded in setup SMS) ───────────────────────
# When a GPS tracker is approved or first connected, the platform sends an SMS
# to the device's SIM card containing these values so the tracker firmware
# knows where to open its JT808 TCP connection and stream location data.
#
# The SMS itself is delivered via HTTPS to the SMS gateway — these variables
# are the CONTENT of that SMS, not the SMS transport configuration.
#
# JT808_HOST — JT808 host written into the device setup SMS.
#              Defaults to APP_DOMAIN when blank (config/sms.php).
#              Override when JT808 TCP is on a different public IP
#              (e.g. a frp VPS). Leave blank for standard setups.
# JT808_PORT — JT808 TCP port written into the device setup SMS.
JT808_HOST=${CFG_JT808_HOST:-}
JT808_PORT=${CFG_JT808_PORT:-7018}

# Device type ID to auto-register when an unknown IMEI first connects.
JT808_DEVICE_TYPE_ID=1

# ── Optional / advanced ───────────────────────────────────────────────────────
# GraphQL M2M bearer token (for server-to-server API calls)
GRAPHQL_KEY=
GRAPHQL_SECRET=

# frp tunnel (docker compose --profile frp up -d)
FRP_SERVER_ADDR=
FRP_TOKEN=change-me
ENV

  ok ".env written — all secrets generated, no manual editing required"

  # Make MYSQL_ROOT_PASSWORD available to wait_for_db in this shell
  MYSQL_ROOT_PASSWORD="${CFG_MYSQL_ROOT_PASS}"
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
  run "mkdir -p '${INSTALL_DIR}/docker/frpc'"
  if ! $DRY_RUN; then
    chmod -R 775 "${INSTALL_DIR}/storage" 2>/dev/null || true
  fi
  ok "Directories ready"
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
# Regenerate with: bash install.sh --update
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
#
# Versions:  login=${TAD_SERVER_LOGIN_TAG}  admin=${TAD_SERVER_ADMIN_TAG}
#            api=${TAD_SERVER_API_TAG}  graphql=${TAD_SERVER_GRAPHQL_TAG}
#            tenant=${TAD_SERVER_TENANT_TAG}  web=${TAD_SERVER_WEB_TAG}
#            jt808=${TAD_JT808_TAG}

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

services:

  login:
    <<: *app-base
    image: ${ORG}/server-login:latest
    container_name: login
    volumes: [app_storage:/app/storage/app]
    environment:
      <<: *app-env
      APP_SURFACE: login
      APP_URL: https://\${LOGIN_DOMAIN}
      APP_KEY: \${LOGIN_APP_KEY}
      SESSION_COOKIE: login_session
      SMS_MASTER_NUMBER:   \${SMS_MASTER_NUMBER:-}
      SMS_GATEWAY_URL:     \${SMS_GATEWAY_URL:-}
      SMS_GATEWAY_API_KEY: \${SMS_GATEWAY_API_KEY:-}

  admin:
    <<: *app-base
    image: ${ORG}/server-admin:latest
    container_name: admin
    volumes: [app_storage:/app/storage/app]
    environment:
      <<: *app-env
      APP_SURFACE: admin
      APP_URL: https://\${ADMIN_DOMAIN}
      APP_KEY: \${ADMIN_APP_KEY}
      SESSION_COOKIE: admin_session
      # APP_SURFACE=admin tells SsoClientServiceProvider which oauth_clients
      # row to load. SSO_SERVER_URL ensures Socialite redirects to the login
      # domain rather than the container's own domain.
      SSO_SERVER_URL: https://\${LOGIN_DOMAIN}

  api:
    <<: *app-base
    image: ${ORG}/server-api:latest
    container_name: api
    environment:
      <<: *app-env
      APP_SURFACE: api
      APP_URL: https://api.\${APP_DOMAIN}
      APP_KEY: \${API_APP_KEY}
      SSO_SERVER_URL: https://\${LOGIN_DOMAIN}
      # JT808 onboarding — sent to devices via SMS to configure their TCP endpoint
      JT808_HOST: \${JT808_HOST:-}
      JT808_PORT: \${JT808_PORT:-7018}

  graphql:
    <<: *app-base
    image: ${ORG}/server-graphql:latest
    container_name: graphql
    environment:
      <<: *app-env
      APP_SURFACE: graphql
      APP_URL: https://\${GRAPHQL_DOMAIN}
      APP_KEY: \${GRAPHQL_APP_KEY}
      SESSION_COOKIE: graphql_session
      SSO_SERVER_URL: https://\${LOGIN_DOMAIN}
      GRAPHQL_KEY:    \${GRAPHQL_KEY:-}
      GRAPHQL_SECRET: \${GRAPHQL_SECRET:-}

  # web (Next.js) is deployed to Cloudflare Pages — not a Docker service.
  # Configure env vars via wrangler.toml or Cloudflare Pages dashboard.
  # Cloudflare Pages handles track-any-device.com directly; no tunnel needed.

  cron:
    <<: *app-base
    image: ${ORG}/server-cron:latest
    container_name: cron
    environment:
      <<: *app-env
      APP_SURFACE: api
      APP_KEY: \${API_APP_KEY}
      JT808_HOST: \${JT808_HOST:-}
      JT808_PORT: \${JT808_PORT:-7018}

  queue:
    <<: *app-base
    image: ${ORG}/server-queue:latest
    container_name: queue
    environment:
      <<: *app-env
      APP_SURFACE: api
      APP_KEY: \${API_APP_KEY}
      JT808_HOST: \${JT808_HOST:-}
      JT808_PORT: \${JT808_PORT:-7018}

  cli:
    image: ${ORG}/server-cli:latest
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
    image: ${ORG}/jt808-server:latest
    container_name: jt808
    ports: ["7018:7018", "9090:9090"]
    networks: [tda]
    restart: unless-stopped
    depends_on:
      mysql: {condition: service_healthy}
      redis: {condition: service_started}
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

  # ── Logging (docker compose --profile logging up -d) ──────────────────────
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

  # ── frp tunnel (docker compose --profile frp up -d) ──────────────────────
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
      FRP_TOKEN:       \${FRP_TOKEN:-change-me}

  # ── GPS simulators (docker compose --profile sim up -d) ───────────────────
  p901-0:
    image: ${ORG}/p901-device:latest
    container_name: p901-0
    networks: [tda]
    restart: unless-stopped
    profiles: [sim]
    depends_on:
      jt808: {condition: service_healthy}
    environment:
      DEVICE_IMEI: "00000000000000"
      SERVER_ADDR: "\${JT808_HOST:-jt808}:\${JT808_PORT:-7018}"
      INITIAL_LAT: "31.5204"
      INITIAL_LON: "74.3587"

  p901-1:
    image: ${ORG}/p901-device:latest
    container_name: p901-1
    networks: [tda]
    restart: unless-stopped
    profiles: [sim]
    depends_on:
      jt808: {condition: service_healthy}
    environment:
      DEVICE_IMEI: "11111111111111"
      SERVER_ADDR: "\${JT808_HOST:-jt808}:\${JT808_PORT:-7018}"
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

  ok "docker-compose.yml generated"
}

# ── Stack operations ──────────────────────────────────────────────────────────
stack_up() {
  local compose="${INSTALL_DIR}/docker-compose.yml"
  log "Pulling images (this may take a few minutes)..."
  run "docker compose -f '${compose}' pull --quiet"

  if docker compose -f "${compose}" ps -q 2>/dev/null | grep -q .; then
    log "Stack running — updating changed services..."
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
  local root_pass="${MYSQL_ROOT_PASSWORD:-}"

  # Source .env if MYSQL_ROOT_PASSWORD not already set
  if [[ -z "$root_pass" ]]; then
    set -a; source "${INSTALL_DIR}/.env" 2>/dev/null || true; set +a
    root_pass="${MYSQL_ROOT_PASSWORD:-}"
  fi

  log "Waiting for MySQL to be ready..."
  local attempts=0
  while ! docker compose -f "${compose}" exec -T mysql \
      mysqladmin ping -u root -p"${root_pass}" --silent &>/dev/null 2>&1; do
    attempts=$((attempts + 1))
    [[ $attempts -ge 30 ]] && { err "MySQL did not become ready within 5 minutes."; exit 1; }
    printf "." >/dev/tty
    sleep 10
  done
  echo "" >/dev/tty
  ok "MySQL ready"
}

wait_for_app() {
  local compose="${INSTALL_DIR}/docker-compose.yml"
  # The 'api' container has the full app code baked in — use it for artisan.
  # The 'cli' container is a tools-only image (PHP+Composer+pnpm) intended
  # for local dev with a bind-mount; it has no artisan without one.
  log "Waiting for API container to be ready..."
  local attempts=0
  until docker compose -f "${compose}" \
      exec -T -w /var/www/html api php artisan --version &>/dev/null 2>&1; do
    attempts=$((attempts + 1))
    [[ $attempts -ge 30 ]] && { err "API container did not become ready within 5 minutes."; exit 1; }
    printf "." >/dev/tty
    sleep 10
  done
  echo "" >/dev/tty
  ok "API container ready"
}

run_seed() {
  local compose="${INSTALL_DIR}/docker-compose.yml"

  log "Running migrations..."
  run "docker compose -f '${compose}' exec -T -w /var/www/html api php artisan migrate --force"
  ok "Migrations complete"

  log "Seeding database (device types, OAuth clients, admin user, sample data)..."
  run "docker compose -f '${compose}' exec -T -w /var/www/html api php artisan db:seed --force"
  ok "Database seeded — OAuth clients created with static IDs"
}

# ── Status display ────────────────────────────────────────────────────────────
show_status() {
  local compose="${INSTALL_DIR}/docker-compose.yml"
  # Source .env for domain display
  set -a; source "${INSTALL_DIR}/.env" 2>/dev/null || true; set +a

  echo ""
  echo -e "${BOLD}── Services ────────────────────────────────────────────────────${RESET}"
  if ! $DRY_RUN; then
    docker compose -f "${compose}" ps --format \
      "table {{.Name}}\t{{.Status}}" 2>/dev/null || true
  fi
  echo ""
  echo -e "${BOLD}── Versions ────────────────────────────────────────────────────${RESET}"
  echo "  server-login:    ${TAD_SERVER_LOGIN_TAG}"
  echo "  server-admin:    ${TAD_SERVER_ADMIN_TAG}"
  echo "  server-api:      ${TAD_SERVER_API_TAG}"
  echo "  server-graphql:  ${TAD_SERVER_GRAPHQL_TAG}"
  echo "  server-tenant:   ${TAD_SERVER_TENANT_TAG}"
  echo "  jt808:           ${TAD_JT808_TAG}"
  echo "  web (CF Pages):  ${TAD_SERVER_WEB_TAG}  ← deployed via Cloudflare Pages"
  echo ""
  echo -e "${BOLD}── Access ──────────────────────────────────────────────────────${RESET}"
  echo "  Web + My portal: https://${APP_DOMAIN:-track-any-device.com}  (Cloudflare Pages)"
  echo "  Admin panel:     https://${ADMIN_DOMAIN:-admin.track-any-device.com}"
  echo "  phpMyAdmin:      http://localhost:3333"
  echo "  MailPit:         http://localhost:8025"
  echo ""
  local jt808_host="${JT808_HOST:-${APP_DOMAIN:-<your-domain>}}"
  local jt808_port="${JT808_PORT:-7018}"
  echo -e "${BOLD}── JT808 GPS Tracker Endpoint ──────────────────────────────────${RESET}"
  echo "  Device setup SMS tells trackers to connect to:"
  echo "    JT808 host: ${jt808_host}"
  echo "    JT808 port: ${jt808_port}  (TCP — written into the SMS body)"
  echo "  Observability:           http://localhost:9090/metrics"
  echo ""
  echo -e "${BOLD}── OAuth clients (static, pre-seeded) ──────────────────────────${RESET}"
  echo "  Web portal:   ${WEB_CLIENT_ID}"
  echo "  Admin panel:  ${ADMIN_CLIENT_ID}"
  echo "  GraphQL:      ${GRAPHQL_CLIENT_ID}"
  echo "  Mobile PKCE:  ${MOBILE_CLIENT_ID}  (no secret)"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════╗"
  echo -e "║   Track Any Device — Platform Installer                          ║"
  echo -e "╚══════════════════════════════════════════════════════════════════╝${RESET}"

  check_prerequisites

  # Always fetch the latest release tags from GitHub before doing anything.
  # Falls back silently to the offline defaults if GitHub is unreachable.
  fetch_versions

  if $UPDATE_ONLY; then
    # ── UPDATE: pull latest versions, regenerate compose, restart, migrate ───
    # Source .env so compose generation has access to all variables
    set -a; source "${INSTALL_DIR}/.env" 2>/dev/null || true; set +a
    generate_compose
    stack_up
    # Apply any pending migrations from new releases automatically.
    wait_for_app
    log "Applying pending migrations..."
    run "docker compose -f '${INSTALL_DIR}/docker-compose.yml' exec -T -w /var/www/html api php artisan migrate --force"
    ok "Migrations up to date."
    show_status
    ok "Update complete."

  else
    # ── FRESH INSTALL: load existing .env if present, then prompt (or skip) ─
    detect_existing_env
    collect_config
    create_directories
    write_env
    generate_compose
    stack_up
    wait_for_db
    wait_for_app
    run_seed
    show_status

    echo -e "${BOLD}${GREEN}"
    echo "  ✓ Installation complete!"
    echo -e "${RESET}"
    echo "  Next steps:"
    echo "    1. Add Cloudflare Tunnel public hostnames (if not already done)"
    echo "    2. Open admin panel → approve your first tenant"
    echo "    3. Add tenant portals: edit docker-compose.yml, add a tenant_* block"
    echo "    4. For GPS tracking: point JT808 devices to :7018"
    echo ""
    echo "  Config saved to: ${INSTALL_DIR}/.env"
    echo "  Update later:    bash ${INSTALL_DIR}/install.sh --update"
    echo ""
  fi
}

# Persist a copy of this script in INSTALL_DIR so future --update works.
# Uses $SCRIPT_SELF (captured before set -u) instead of BASH_SOURCE[0].
_persist_script() {
  ! $DRY_RUN && ! $UPDATE_ONLY || return 0
  mkdir -p "${INSTALL_DIR}" 2>/dev/null || true

  if [[ -n "$SCRIPT_SELF" && "$SCRIPT_SELF" != "${INSTALL_DIR}/install.sh" ]]; then
    # Running as a regular file — copy it
    cp "$SCRIPT_SELF" "${INSTALL_DIR}/install.sh" 2>/dev/null \
      && chmod +x "${INSTALL_DIR}/install.sh" || true
  elif [[ -z "$SCRIPT_SELF" ]]; then
    # Running via curl | bash — download a copy from GitHub
    curl -fsSL --max-time 15 \
      "https://raw.githubusercontent.com/track-any-device/.github/main/install.sh" \
      -o "${INSTALL_DIR}/install.sh" 2>/dev/null \
      && chmod +x "${INSTALL_DIR}/install.sh" || true
  fi
}

_persist_script
main "$@"
