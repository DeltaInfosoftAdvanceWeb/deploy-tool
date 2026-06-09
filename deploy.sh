#!/bin/bash

# ── Universal Next.js Deploy Script ──────────────────────────────────────────
# Version: 3.0.0
#
# Changes from 2.3.1:
#   - FIX: R2 removed (was dead code — wrong container names, never matched)
#   - FIX: Local tar file deleted after successful upload (was never cleaned up)
#   - NEW: ./deploy.sh rollback — manually restore :rollback image anytime
#   - FIX: Startup wait replaced hardcoded 30s sleep with 2s polling (max 60s)
#   - FIX: Real health check — hits http://localhost:PORT not just "is Up?"
#   - FIX: macOS Keychain falls back to .secrets file (works on Linux/CI too)
#   - NEW: Clients stored in deploy.config.sh (not .env) with multiple URLs
#   - FIX: All errors clearly labelled with WHAT failed and WHY — no silent failures
#
# Usage:
#   ./deploy.sh           → build image + export tar (local only)
#   ./deploy.sh push      → build + upload + restart on server
#   ./deploy.sh push --client GCKC → deploy for specific client
#   ./deploy.sh restart   → just restart containers on server
#   ./deploy.sh rollback  → restore previous :rollback image on server
#   ./deploy.sh stop      → stop everything on server
#   ./deploy.sh logs      → tail server logs
#   ./deploy.sh local     → run locally for testing
#   ./deploy.sh client --list        → list all clients in deploy.config.sh
#   ./deploy.sh client --add         → add new client to deploy.config.sh
#   ./deploy.sh client --remove NAME → remove client from deploy.config.sh
# ─────────────────────────────────────────────────────────────────────────────

DEPLOY_VERSION="3.0.0"

# ── Colors ────────────────────────────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

STEP_START=0
ts()      { date '+%H:%M:%S'; }
elapsed() { echo "$((SECONDS - STEP_START))s"; }

step_start() { STEP_START=$SECONDS; printf "${CYAN}[$(ts)]${NC} ${BOLD}▶ %s${NC}\n" "$1"; }
step_ok()    { printf "${GREEN}[$(ts)]${NC} ${GREEN}✅ %s${NC} ${DIM}($(elapsed))${NC}\n\n" "$1"; }
step_warn()  { printf "${YELLOW}[$(ts)]${NC} ${YELLOW}⚠️  %s${NC}\n" "$1"; }
step_err()   { printf "${RED}[$(ts)]${NC} ${RED}❌ %s${NC}\n" "$1"; }
info()       { printf "${DIM}[$(ts)] %s${NC}\n" "$1"; }

print_header() {
  printf "\n${BOLD}${BLUE}══════════════════════════════════════════${NC}\n"
  printf "${BOLD}${BLUE} %s — %s${NC}\n" "$APP_NAME" "$1"
  printf "${BOLD}${BLUE}══════════════════════════════════════════${NC}\n"
  printf "${DIM} Version : %s${NC}\n" "$DEPLOY_VERSION"
  printf "${DIM} Started : %s${NC}\n\n" "$(date '+%Y-%m-%d %H:%M:%S')"
}

print_divider() { printf "${DIM} ──────────────────────────────────────────${NC}\n"; }

print_summary() {
  printf "\n${BOLD}${MAGENTA}══════════════════════════════════════════${NC}\n"
  printf "${BOLD}${MAGENTA} Summary${NC}\n"
  printf "${BOLD}${MAGENTA}══════════════════════════════════════════${NC}\n"
}

# ── OS-safe file size ─────────────────────────────────────────────────────────
file_bytes() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    stat -f%z "$1" 2>/dev/null || echo 0
  else
    stat -c%s "$1" 2>/dev/null || echo 0
  fi
}

# ── Load config ───────────────────────────────────────────────────────────────
CONFIG_FILE="$(dirname "$0")/deploy.config.sh"
if [ ! -f "$CONFIG_FILE" ]; then
  printf "${RED}❌ deploy.config.sh not found.${NC}\n"
  printf "   Run: setup-deploy\n"
  exit 1
fi
source "$CONFIG_FILE"

# ── Read IMAGE_NAME — from config first, then docker-compose.yml ─────────────
# IMAGE_NAME is now stored in deploy.config.sh (set during setup-deploy).
# Falls back to docker-compose.yml for backwards compatibility.
if [ -z "$IMAGE_NAME" ]; then
  if [ -f "docker-compose.yml" ]; then
    IMAGE_NAME=$(grep -E '^\s*image\s*:' docker-compose.yml | head -1 \
      | sed 's/.*image\s*:\s*//' | sed 's/:.*//' | tr -d ' "'"'")
  fi
fi

if [ -z "$IMAGE_NAME" ]; then
  printf "${RED}❌ IMAGE_NAME not found.${NC}\n"
  printf "   Fix option 1: Re-run setup-deploy to set image name in deploy.config.sh\n"
  printf "   Fix option 2: Add 'image: myapp' line to docker-compose.yml\n"
  exit 1
fi

# ── Load server password ──────────────────────────────────────────────────────
# Tries macOS Keychain first, falls back to .secrets file (Linux/CI compatible)
_load_server_pass() {
  local pass=""

  # macOS Keychain
  if command -v security &>/dev/null; then
    pass=$(security find-generic-password -a "$SERVER_USER" -s "deploy-${APP_NAME}-server" -w 2>/dev/null || echo "")
  fi

  # Fallback: .secrets file (chmod 600 recommended)
  if [ -z "$pass" ] && [ -f "$(dirname "$0")/.secrets" ]; then
    pass=$(grep -E '^SERVER_PASS=' "$(dirname "$0")/.secrets" | head -1 | sed 's/SERVER_PASS=//' | tr -d '"'"'" | tr -d "'")
  fi

  # Fallback: env variable (CI/CD)
  if [ -z "$pass" ] && [ -n "$DEPLOY_SERVER_PASS" ]; then
    pass="$DEPLOY_SERVER_PASS"
  fi

  echo "$pass"
}

SERVER_PASS=$(_load_server_pass)

if [ -z "$SERVER_PASS" ]; then
  printf "${RED}❌ Server password not found.${NC}\n"
  printf "   Tried: macOS Keychain → .secrets file → DEPLOY_SERVER_PASS env var\n"
  printf "   Fix (macOS): cd your-project && setup-deploy --update-secrets\n"
  printf "   Fix (Linux): echo 'SERVER_PASS=yourpassword' > .secrets && chmod 600 .secrets\n"
  printf "   Fix (CI):    export DEPLOY_SERVER_PASS=yourpassword\n"
  exit 1
fi

# ── Parse arguments ───────────────────────────────────────────────────────────
CMD="${1:-build}"
CLIENT_NAME=""
for i in "$@"; do
  if [ "$i" = "--client" ]; then
    shift
    CLIENT_NAME="$1"
    break
  fi
done

# ── SSH helpers ───────────────────────────────────────────────────────────────
remote() {
  if command -v sshpass &>/dev/null && [ -n "$SERVER_PASS" ]; then
    sshpass -p "$SERVER_PASS" ssh \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=15 \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=3 \
      "$SERVER_USER@$SERVER_IP" "$@"
  else
    ssh \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=15 \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=3 \
      "$SERVER_USER@$SERVER_IP" "$@"
  fi
}

push_file_progress() {
  local src="$1"
  local dst="$2"
  local filename
  filename=$(basename "$src")
  local filesize
  filesize=$(du -sh "$src" 2>/dev/null | cut -f1)

  info "  File : $filename"
  info "  Size : $filesize"
  info "  Dest : $SERVER_USER@$SERVER_IP:$dst"
  printf "\n"

  local TRANSFER_START=$SECONDS

  if command -v rsync &>/dev/null; then
    info "Using rsync (with live progress)..."
    if command -v sshpass &>/dev/null && [ -n "$SERVER_PASS" ]; then
      sshpass -p "$SERVER_PASS" rsync -avz --checksum --progress \
        -e "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15" \
        "$src" "$SERVER_USER@$SERVER_IP:$dst" || {
          step_err "TRANSFER FAILED: Could not upload $filename"
          printf "   Reason: rsync exited with error\n"
          printf "   Check: server reachable, disk space available, path exists\n"
          exit 1
        }
    else
      rsync -avz --checksum --progress \
        -e "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15" \
        "$src" "$SERVER_USER@$SERVER_IP:$dst" || {
          step_err "TRANSFER FAILED: Could not upload $filename"
          printf "   Check: SSH keys configured, server reachable\n"
          exit 1
        }
    fi
  else
    info "rsync not found — using scp..."
    if command -v sshpass &>/dev/null && [ -n "$SERVER_PASS" ]; then
      sshpass -p "$SERVER_PASS" scp \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=15 \
        "$src" "$SERVER_USER@$SERVER_IP:$dst" || {
          step_err "TRANSFER FAILED: scp could not upload $filename"
          printf "   Fix: brew install hudochenkov/sshpass/sshpass\n"
          exit 1
        }
    else
      scp \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=15 \
        "$src" "$SERVER_USER@$SERVER_IP:$dst" || {
          step_err "TRANSFER FAILED: scp could not upload $filename"
          exit 1
        }
    fi
  fi

  local transfer_elapsed=$((SECONDS - TRANSFER_START))
  local bytes
  bytes=$(file_bytes "$src")
  local speed=0
  if [ "$transfer_elapsed" -gt 0 ] && [ "$bytes" -gt 0 ]; then
    speed=$(( bytes / transfer_elapsed / 1024 ))
  fi

  info "  Transfer time : ${transfer_elapsed}s"
  [ "$speed" -gt 0 ] && info "  Avg speed     : ${speed} KB/s"
}

check_ssh() {
  step_start "Testing SSH connection to $SERVER_USER@$SERVER_IP..."
  if remote "echo 'SSH OK'" 2>&1; then
    step_ok "SSH connection successful"
  else
    step_err "SSH CONNECTION FAILED: Cannot connect to $SERVER_IP"
    printf "   Possible reasons:\n"
    printf "   - Wrong IP address   : %s\n" "$SERVER_IP"
    printf "   - Wrong username     : %s\n" "$SERVER_USER"
    printf "   - Wrong password     → run: setup-deploy --update-secrets\n"
    printf "   - Server is offline\n"
    printf "   - SSH port blocked by firewall\n"
    exit 1
  fi
}

# ── Validate docker-compose.yml has ports mapping ─────────────────────────────
check_compose_ports() {
  if ! grep -qE 'ports:' docker-compose.yml; then
    step_warn "No 'ports:' section found in docker-compose.yml"
    printf "   Without a ports mapping the app will not be accessible from outside.\n"
    printf "   Expected:\n"
    printf "     ports:\n"
    printf "       - \"%s:3000\"\n" "$APP_PORT"
    printf "   Continue anyway? (y/N): " >&2
    read _compose_confirm
    if [ "$_compose_confirm" != "y" ] && [ "$_compose_confirm" != "Y" ]; then
      printf "   Aborted. Fix docker-compose.yml and try again.\n"
      exit 1
    fi
  fi
}

# ── Client helpers — read from deploy.config.sh ───────────────────────────────

# Returns space-separated list of client names defined in config
get_config_clients() {
  echo "${API_CLIENTS:-}"
}

# Returns the URL array var name for a client: CLIENT_GCKC_URLS
_client_urls_var() {
  echo "CLIENT_$1_URLS"
}

# Returns the ID var name for a client: CLIENT_GCKC_ID
_client_id_var() {
  echo "CLIENT_$1_ID"
}

# Get all URL lines for a client (from array in config)
get_client_urls() {
  local client="$1"
  local var
  var=$(_client_urls_var "$client")
  # eval the array from config (already sourced)
  eval "local urls=(\"\${${var}[@]}\")"
  for url in "${urls[@]}"; do
    echo "$url"
  done
}

# Get client ID (optional)
get_client_id() {
  local client="$1"
  local var
  var=$(_client_id_var "$client")
  eval "echo \"\${${var}:-}\""
}

# Build a temp .env with client URLs injected (replaces matching keys, appends new ones)
build_client_env() {
  local client="$1"
  local base_env=".env"

  if [ ! -f "$base_env" ]; then
    step_err "BUILD CLIENT ENV FAILED: .env file not found"
    printf "   Create a .env file in your project root first\n"
    exit 1
  fi

  local client_id
  client_id=$(get_client_id "$client")

  # Collect client URL lines
  local url_lines=()
  while IFS= read -r line; do
    [ -n "$line" ] && url_lines+=("$line")
  done < <(get_client_urls "$client")

  if [ ${#url_lines[@]} -eq 0 ]; then
    step_err "BUILD CLIENT ENV FAILED: No URLs found for client '$client'"
    printf "   Run: ./deploy.sh client --list to check defined clients\n"
    exit 1
  fi

  # Build list of keys defined for this client
  local client_keys=()
  for line in "${url_lines[@]}"; do
    local key
    key=$(echo "$line" | cut -d'=' -f1)
    client_keys+=("$key")
  done
  [ -n "$client_id" ] && client_keys+=("CLIENT_ID")

  # Start with base .env, stripping lines whose keys will be replaced
  local tmp_env
  tmp_env=$(mktemp)

  while IFS= read -r line; do
    local skip=0
    for key in "${client_keys[@]}"; do
      if echo "$line" | grep -qE "^[[:space:]]*${key}[[:space:]]*="; then
        skip=1; break
      fi
    done
    [ "$skip" -eq 0 ] && echo "$line"
  done < "$base_env" > "$tmp_env"

  # Append client-specific URLs
  printf "\n# ── Client: %s ──\n" "$client" >> "$tmp_env"
  for line in "${url_lines[@]}"; do
    echo "$line" >> "$tmp_env"
  done

  # Append CLIENT_ID if set
  if [ -n "$client_id" ]; then
    echo "CLIENT_ID=${client_id}" >> "$tmp_env"
  fi

  echo "$tmp_env"
}

# ── Client management ─────────────────────────────────────────────────────────

do_client_list() {
  local clients
  clients=$(get_config_clients)

  printf "\n${BOLD}${CYAN} Clients defined in deploy.config.sh:${NC}\n\n"

  if [ -z "$clients" ]; then
    printf "  ${DIM}No clients found. Add one with: ./deploy.sh client --add${NC}\n\n"
    return
  fi

  local i=1
  for client in $clients; do
    local client_id
    client_id=$(get_client_id "$client")
    printf "  ${BOLD}%d. %s${NC}%s\n" "$i" "$client" \
      "${client_id:+  (ID: $client_id)}"

    while IFS= read -r url_line; do
      printf "     ${DIM}%s${NC}\n" "$url_line"
    done < <(get_client_urls "$client")

    printf "\n"
    i=$((i+1))
  done
}

do_client_add() {
  printf "\n${BOLD}${CYAN} Add New Client${NC}\n\n"

  # Client name
  local client_name=""
  while true; do
    printf "  ? Client name (e.g. GCKC, DARA): " >&2
    read client_name
    if [ -z "$client_name" ]; then
      printf "  ${RED}❌ Client name cannot be empty.${NC}\n" >&2; continue
    fi
    if ! echo "$client_name" | grep -qE '^[a-zA-Z0-9_-]+$'; then
      printf "  ${RED}❌ No spaces or special characters allowed.${NC}\n" >&2; continue
    fi
    local existing
    existing=$(get_config_clients)
    if echo "$existing" | grep -qw "$client_name"; then
      printf "  ${RED}❌ Client '%s' already exists.${NC}\n" "$client_name" >&2; continue
    fi
    break
  done

  # Multiple URLs
  printf "\n  ${DIM}Paste your .env URL lines one by one (KEY=VALUE format).${NC}\n"
  printf "  ${DIM}Press Enter on a blank line when done.${NC}\n"
  printf "  ${DIM}Example:${NC}\n"
  printf "  ${DIM}  NEXT_PUBLIC_API_BASE_URL=http://delta.gckc.com:901/api${NC}\n"
  printf "  ${DIM}  NEXT_PUBLIC_AUTH_URL=http://delta.gckc.com${NC}\n\n"

  local url_lines=()
  local url_count=0
  while true; do
    printf "  URL line %d (blank to finish): " "$((url_count+1))" >&2
    local url_line=""
    read url_line

    # Blank line = done
    if [ -z "$url_line" ]; then
      if [ ${#url_lines[@]} -eq 0 ]; then
        printf "  ${RED}❌ At least one URL is required.${NC}\n" >&2
        continue
      fi
      break
    fi

    # Must be KEY=VALUE
    if ! echo "$url_line" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*=.+'; then
      printf "  ${RED}❌ Must be in KEY=VALUE format. Example: NEXT_PUBLIC_API_BASE_URL=http://...${NC}\n" >&2
      continue
    fi

    # Value must start with http
    local url_val
    url_val=$(echo "$url_line" | cut -d'=' -f2-)
    if ! echo "$url_val" | grep -qE '^https?://'; then
      printf "  ${RED}❌ URL value must start with http:// or https://. You entered: %s${NC}\n" "$url_val" >&2
      continue
    fi

    url_lines+=("$url_line")
    url_count=$((url_count+1))
    printf "  ${GREEN}✅ Added${NC}\n" >&2
  done

  # Optional Client ID
  printf "\n  ? Client ID for %s (optional, press Enter to skip): " "$client_name" >&2
  local client_id=""
  read client_id

  # Preview
  printf "\n  ${BOLD}Preview for %s:${NC}\n" "$client_name"
  for line in "${url_lines[@]}"; do
    printf "  ${DIM}%s${NC}\n" "$line"
  done
  [ -n "$client_id" ] && printf "  ${DIM}CLIENT_ID=%s${NC}\n" "$client_id"

  printf "\n  Confirm add? (y/N): " >&2
  local confirm=""
  read confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    printf "  Aborted.\n\n"; return
  fi

  # Write to deploy.config.sh
  local config_file
  config_file="$(dirname "$0")/deploy.config.sh"

  # Update API_CLIENTS list
  local existing_clients
  existing_clients=$(get_config_clients)
  local new_clients="${existing_clients:+$existing_clients }${client_name}"

  # Build URLs array block
  local array_block
  array_block="CLIENT_${client_name}_URLS=(\n"
  for line in "${url_lines[@]}"; do
    array_block+="  \"${line}\"\n"
  done
  array_block+=")"

  # Append to config
  {
    printf "\n# ── Client: %s ──────────────────────────────────────────\n" "$client_name"
    printf "%b\n" "$array_block"
    printf "CLIENT_%s_ID=\"%s\"\n" "$client_name" "$client_id"
  } >> "$config_file"

  # Update API_CLIENTS= line in config
  local tmp
  tmp=$(mktemp)
  sed "s/^API_CLIENTS=.*/API_CLIENTS=\"${new_clients}\"/" "$config_file" > "$tmp"
  mv "$tmp" "$config_file"

  printf "\n${GREEN}  ✅ Client '%s' added to deploy.config.sh${NC}\n" "$client_name"
  printf "  ${DIM}Deploy with: ./deploy.sh push --client %s${NC}\n\n" "$client_name"
}

do_client_remove() {
  local client="$3"
  if [ -z "$client" ]; then
    printf "  Usage: ./deploy.sh client --remove CLIENT_NAME\n"
    exit 1
  fi

  local existing
  existing=$(get_config_clients)
  if ! echo "$existing" | grep -qw "$client"; then
    step_err "REMOVE FAILED: Client '$client' not found in deploy.config.sh"
    do_client_list
    exit 1
  fi

  printf "\n  ${YELLOW}⚠️  Remove client '%s' from deploy.config.sh?${NC}\n" "$client"
  printf "  This will permanently delete its URL block and ID.\n"
  printf "  Confirm? (y/N): " >&2
  local confirm=""
  read confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    printf "  Aborted.\n\n"; exit 0
  fi

  local config_file
  config_file="$(dirname "$0")/deploy.config.sh"
  local tmp
  tmp=$(mktemp)

  # Remove the client block (comment header + URLS array + ID line)
  awk -v client="$client" '
    /^# ── Client: / && index($0, client) > 0 { skip=1; next }
    skip && /^CLIENT_/ && index($0, client) > 0 { next }
    skip && /^\)/ { skip=0; next }
    skip { next }
    { print }
  ' "$config_file" > "$tmp"

  # Update API_CLIENTS list
  local new_clients
  new_clients=$(echo "$existing" | tr ' ' '\n' | grep -v "^${client}$" | tr '\n' ' ' | xargs)
  sed -i.bak "s/^API_CLIENTS=.*/API_CLIENTS=\"${new_clients}\"/" "$tmp"
  rm -f "${tmp}.bak"

  mv "$tmp" "$config_file"
  printf "${GREEN}  ✅ Client '%s' removed from deploy.config.sh${NC}\n\n" "$client"
}

# ── Build ─────────────────────────────────────────────────────────────────────
do_build() {
  local BUILD_TOTAL_START=$SECONDS

  print_header "Build"

  if [ ! -f "Dockerfile" ]; then
    step_err "BUILD FAILED: Dockerfile not found in current directory"
    printf "   Make sure you are running this from your project root folder\n"
    printf "   Current dir: $(pwd)\n"
    exit 1
  fi

  step_start "Building Docker image for linux/amd64..."
  info "  Image name : $IMAGE_NAME:latest"
  info "  Platform   : linux/amd64"
  printf "\n"

  set -o pipefail
  docker build --platform linux/amd64 -t "$IMAGE_NAME:latest" . 2>&1 | \
    while IFS= read -r line; do
      if echo "$line" | grep -qiE "^(#[0-9]|Step [0-9])"; then
        printf "  ${CYAN}%s${NC}\n" "$line"
      elif echo "$line" | grep -qiE "error|failed|cannot|denied"; then
        printf "  ${RED}%s${NC}\n" "$line"
      elif echo "$line" | grep -qiE "warn|warning"; then
        printf "  ${YELLOW}%s${NC}\n" "$line"
      elif echo "$line" | grep -qiE "successfully|complete|done|cached"; then
        printf "  ${GREEN}%s${NC}\n" "$line"
      else
        printf "  ${DIM}%s${NC}\n" "$line"
      fi
    done

  local BUILD_EXIT=$?
  set +o pipefail

  if [ $BUILD_EXIT -ne 0 ]; then
    step_err "BUILD FAILED: docker build exited with code $BUILD_EXIT"
    printf "   Fix the Dockerfile error shown above, then run: ./deploy.sh push\n"
    exit 1
  fi

  step_ok "Docker image built successfully"

  step_start "Checking image details..."
  printf "\n"
  docker images "$IMAGE_NAME:latest" --format "  ID: {{.ID}}\n  Size: {{.Size}}\n  Created: {{.CreatedAt}}"
  printf "\n"
  step_ok "Image info retrieved"

  step_start "Exporting image to $TAR_FILE..."
  info "  This may take 1-3 minutes depending on image size..."
  printf "\n"

  local EXPORT_START=$SECONDS
  docker save "$IMAGE_NAME:latest" | gzip > "$TAR_FILE" || {
    step_err "EXPORT FAILED: Could not write $TAR_FILE"
    printf "   Check disk space: df -h .\n"
    exit 1
  }

  local EXPORT_TIME=$((SECONDS - EXPORT_START))
  local SIZE
  SIZE=$(du -sh "$TAR_FILE" | cut -f1)

  info "  Output file  : $TAR_FILE"
  info "  File size    : $SIZE"
  info "  Export time  : ${EXPORT_TIME}s"
  printf "\n"
  step_ok "Image exported successfully"

  print_summary
  printf "  ${GREEN}✅ Image built and exported${NC}\n"
  printf "  ${DIM} Total build time : %ss${NC}\n\n" "$((SECONDS - BUILD_TOTAL_START))"
  printf "  To deploy: ./deploy.sh push\n\n"
}

# ── Push ──────────────────────────────────────────────────────────────────────
do_push() {
  local PUSH_TOTAL_START=$SECONDS
  local DEPLOY_CLIENT=""
  local ENV_FILE=".env"
  local CLEAN_ENV_FILE=""

  if [ ! -f ".env" ]; then
    step_err "PUSH FAILED: .env file not found in current directory"
    printf "   Create a .env file with your environment variables first\n"
    exit 1
  fi

  # ── Client selection ──────────────────────────────────────────────────────
  local available_clients
  available_clients=$(get_config_clients)

  if [ -n "$available_clients" ]; then
    if [ -n "$CLIENT_NAME" ]; then
      # --client flag passed directly
      if ! echo "$available_clients" | grep -qw "$CLIENT_NAME"; then
        step_err "PUSH FAILED: Client '$CLIENT_NAME' not found in deploy.config.sh"
        printf "   Available clients: %s\n" "$available_clients"
        printf "   Run: ./deploy.sh client --list\n"
        exit 1
      fi
      DEPLOY_CLIENT="$CLIENT_NAME"
    else
      # Interactive selection
      printf "\n${BOLD}${CYAN} Available clients in deploy.config.sh:${NC}\n\n"
      local i=1
      local client_list=()
      for c in $available_clients; do
        local cid
        cid=$(get_client_id "$c")
        printf "  ${BOLD}%d. %s${NC}%s\n" "$i" "$c" "${cid:+  (ID: $cid)}"
        while IFS= read -r url_line; do
          printf "     ${DIM}%s${NC}\n" "$url_line"
        done < <(get_client_urls "$c")
        client_list+=("$c")
        i=$((i+1))
      done
      printf "\n"
      printf "  ? Enter client number or name (or press Enter to deploy as-is): " >&2
      local client_input=""
      read client_input

      if [ -n "$client_input" ]; then
        if echo "$client_input" | grep -qE '^[0-9]+$'; then
          DEPLOY_CLIENT="${client_list[$((client_input-1))]}"
          if [ -z "$DEPLOY_CLIENT" ]; then
            step_err "PUSH FAILED: Invalid client number '$client_input'"
            exit 1
          fi
        else
          if ! echo "$available_clients" | grep -qw "$client_input"; then
            step_err "PUSH FAILED: Client '$client_input' not found"
            printf "   Available: %s\n" "$available_clients"
            exit 1
          fi
          DEPLOY_CLIENT="$client_input"
        fi
      fi
    fi

    if [ -n "$DEPLOY_CLIENT" ]; then
      step_start "Preparing .env for client: $DEPLOY_CLIENT"
      CLEAN_ENV_FILE=$(build_client_env "$DEPLOY_CLIENT")
      ENV_FILE="$CLEAN_ENV_FILE"
      step_ok "Clean .env prepared for $DEPLOY_CLIENT"
    fi
  fi

  print_header "Push to $SERVER_IP${DEPLOY_CLIENT:+ ($DEPLOY_CLIENT)}"

  check_compose_ports

  # ── Build ─────────────────────────────────────────────────────────────────
  do_build

  print_divider

  if ! command -v sshpass &>/dev/null; then
    step_warn "sshpass not found — will use SSH keys instead"
    info "Install with: brew install hudochenkov/sshpass/sshpass"
    printf "\n"
  fi

  check_ssh

  print_divider

  # ── Create remote folder ──────────────────────────────────────────────────
  step_start "Creating folder on server: $SERVER_PATH"
  remote "mkdir -p $SERVER_PATH && echo 'Folder ready'" || {
    step_err "REMOTE SETUP FAILED: Could not create $SERVER_PATH on server"
    printf "   Check SSH permissions and server path\n"
    exit 1
  }
  step_ok "Remote folder ready"

  # ── Disk space check ──────────────────────────────────────────────────────
  step_start "Checking remote disk space before upload..."
  printf "\n"

  local LOCAL_TAR_BYTES
  LOCAL_TAR_BYTES=$(file_bytes "$TAR_FILE")
  local LOCAL_TAR_MB=$(( LOCAL_TAR_BYTES / 1024 / 1024 ))
  local NEEDED=$(( LOCAL_TAR_MB * 2 ))

  info "  Tar file size : ${LOCAL_TAR_MB}MB — need at least ${NEEDED}MB free on server"

  local REMOTE_FREE
  REMOTE_FREE=$(remote "df -m $SERVER_PATH | awk 'NR==2{print \$4}'" 2>/dev/null || echo 0)

  if [ "$REMOTE_FREE" -lt "$NEEDED" ] 2>/dev/null; then
    step_err "DISK SPACE CHECK FAILED: Not enough space on server"
    printf "   Free : ${REMOTE_FREE}MB\n"
    printf "   Need : ${NEEDED}MB\n"
    printf "   Free up space on the server before deploying\n"
    [ -n "$CLEAN_ENV_FILE" ] && rm -f "$CLEAN_ENV_FILE"
    exit 1
  fi

  info "  Free space : ${REMOTE_FREE}MB — OK"
  printf "\n"
  step_ok "Disk space sufficient"

  print_divider

  # ── Upload files ──────────────────────────────────────────────────────────
  printf "${BOLD}[$(ts)] Transferring files to server...${NC}\n\n"

  step_start "Uploading Docker image tar..."
  push_file_progress "$TAR_FILE" "$SERVER_PATH/"
  step_ok "Docker image tar uploaded"

  # ── FIX: Delete local tar after successful upload ─────────────────────────
  step_start "Cleaning up local tar file..."
  rm -f "$TAR_FILE" && {
    step_ok "Local tar deleted (disk freed on your machine)"
  } || {
    step_warn "Could not delete local tar file: $TAR_FILE (not critical)"
  }

  # ── Generate and upload docker-compose.yml ────────────────────────────────
  step_start "Generating production docker-compose.yml..."
  local PROD_COMPOSE
  PROD_COMPOSE=$(mktemp /tmp/docker-compose-prod-XXXX.yml)

  cat > "$PROD_COMPOSE" << COMPOSEFILE
services:
  app:
    image: ${IMAGE_NAME}:latest
    ports:
      - "${APP_PORT}:3000"
    environment:
      - NODE_ENV=production
      - PORT=3000
      - HOSTNAME=0.0.0.0
    env_file:
      - .env
    restart: unless-stopped
COMPOSEFILE

  step_ok "Production docker-compose.yml generated"

  step_start "Uploading docker-compose.yml..."
  push_file_progress "$PROD_COMPOSE" "$SERVER_PATH/docker-compose.yml"
  rm -f "$PROD_COMPOSE"
  step_ok "docker-compose.yml uploaded"

  step_start "Uploading .env${DEPLOY_CLIENT:+ (for $DEPLOY_CLIENT)}..."
  push_file_progress "$ENV_FILE" "$SERVER_PATH/.env"
  step_ok ".env uploaded"
  [ -n "$CLEAN_ENV_FILE" ] && rm -f "$CLEAN_ENV_FILE"

  step_start "Verifying files on server..."
  printf "\n"
  remote "ls -lh $SERVER_PATH/ | awk '{print \"  \"\$0}'" || true
  printf "\n"
  step_ok "Files verified on server"

  print_divider

  # ── Remote deploy block ───────────────────────────────────────────────────
  printf "${BOLD}[$(ts)] Loading image and restarting on server...${NC}\n\n"

  remote bash << REMOTE
set -eo pipefail

# ── Detect docker command ─────────────────────────────────────────────────
if groups | grep -q docker 2>/dev/null; then
  DCMD="docker"
else
  DCMD="sudo docker"
fi

echo "  [REMOTE] Docker command : \$DCMD"
echo "  [REMOTE] Working path   : $SERVER_PATH"
echo ""

cd $SERVER_PATH || {
  echo "  ❌ ERROR: Could not cd into $SERVER_PATH"
  echo "     The folder may not exist or permissions are wrong"
  exit 1
}

# ── R1: Stop existing containers ──────────────────────────────────────────
echo "  ── R1: Stopping existing containers ─────────────────────────────"
\$DCMD compose down --remove-orphans 2>&1 | sed 's/^/     /' || true
echo "  ✅ R1 done"
echo ""

# NOTE: R2 (docker rm by name) has been removed — it used wrong container
# names and never matched anything. R1 (compose down) handles cleanup correctly.

# ── R2 (new): Check port conflicts ────────────────────────────────────────
echo "  ── R2: Checking port $APP_PORT for conflicts ─────────────────────"
CONFLICTING=\$(\$DCMD ps -q --filter "publish=$APP_PORT" 2>/dev/null || echo "")
if [ -n "\$CONFLICTING" ]; then
  echo "     ⚠️  Found containers using port $APP_PORT — removing them"
  \$DCMD rm -f \$CONFLICTING 2>&1 | sed 's/^/     /' || true
else
  echo "     No port conflicts on $APP_PORT"
fi
echo "  ✅ R2 done"
echo ""

# ── R3: Save current image as :rollback ──────────────────────────────────
echo "  ── R3: Saving current image as rollback ──────────────────────────"
ROLLBACK_TAG="${IMAGE_NAME}:rollback"
ROLLBACK_AVAILABLE=0

if \$DCMD image inspect ${IMAGE_NAME}:latest &>/dev/null 2>&1; then
  if \$DCMD tag ${IMAGE_NAME}:latest \$ROLLBACK_TAG 2>/dev/null; then
    echo "     ✅ Saved existing image as \$ROLLBACK_TAG"
    ROLLBACK_AVAILABLE=1
  else
    echo "     ⚠️  Could not tag existing image — rollback not available for this deploy"
  fi
else
  echo "     No existing image found — fresh deploy, rollback not needed"
fi
echo ""

# ── R4: Load new Docker image ─────────────────────────────────────────────
echo "  ── R4: Loading new Docker image ──────────────────────────────────"

TAR_PATH="$SERVER_PATH/$TAR_FILE"

if [ ! -f "\$TAR_PATH" ]; then
  echo "  ❌ ERROR: Tar file not found at \$TAR_PATH"
  echo "     The upload may have failed or the filename is wrong"
  if [ "\$ROLLBACK_AVAILABLE" -eq 1 ]; then
    echo "  ↩️  Rolling back to previous image..."
    \$DCMD tag \$ROLLBACK_TAG ${IMAGE_NAME}:latest && \$DCMD compose up -d
    echo "  ✅ Rollback complete — old version is live again"
  fi
  exit 1
fi

LOAD_START=\$SECONDS
if ! \$DCMD load -i "\$TAR_PATH" 2>&1 | sed 's/^/     /'; then
  echo "  ❌ ERROR: docker load failed — image could not be loaded"
  echo "     The tar file may be corrupted or incomplete"
  if [ "\$ROLLBACK_AVAILABLE" -eq 1 ]; then
    echo "  ↩️  Rolling back to previous image..."
    \$DCMD tag \$ROLLBACK_TAG ${IMAGE_NAME}:latest && \$DCMD compose up -d
    echo "  ✅ Rollback complete — old version is live again"
  fi
  exit 1
fi

echo "     Load time: \$((SECONDS - LOAD_START))s"
echo "  ✅ R4 done"
echo ""

# ── R5: Delete tar from server ────────────────────────────────────────────
echo "  ── R5: Cleaning up tar from server ───────────────────────────────"
rm -f "\$TAR_PATH" && echo "     ✅ Tar file deleted (disk freed)" \
  || echo "     ⚠️  Could not delete tar — remove manually: rm \$TAR_PATH"
echo ""

# ── R6: Show available images ─────────────────────────────────────────────
echo "  ── R6: Available images ──────────────────────────────────────────"
\$DCMD images | grep -E "REPOSITORY|${IMAGE_NAME}" | sed 's/^/     /' || true
echo ""

# ── R7: Start new containers ──────────────────────────────────────────────
echo "  ── R7: Starting new containers ───────────────────────────────────"
if ! \$DCMD compose up -d 2>&1 | sed 's/^/     /'; then
  echo "  ❌ ERROR: docker compose up failed"
  echo "     The docker-compose.yml or .env may have errors"
  if [ "\$ROLLBACK_AVAILABLE" -eq 1 ]; then
    echo "  ↩️  Rolling back to previous image..."
    \$DCMD tag \$ROLLBACK_TAG ${IMAGE_NAME}:latest
    \$DCMD compose up -d 2>&1 | sed 's/^/     /'
    echo "  ✅ Rollback complete — old version is live again"
  fi
  exit 1
fi
echo "  ✅ R7 done"
echo ""

# ── R8: Poll for container startup (max 60s, check every 2s) ─────────────
echo "  ── R8: Waiting for container to start (max 60s) ─────────────────"
BOOT_START=\$SECONDS
BOOTED=0
while [ \$((SECONDS - BOOT_START)) -lt 60 ]; do
  RUNNING=\$(\$DCMD compose ps 2>/dev/null | { grep -c "Up\|running" || true; })
  if [ "\$RUNNING" -gt 0 ]; then
    BOOTED=1
    break
  fi
  echo "     ⏳ \$((SECONDS - BOOT_START))s — waiting..."
  sleep 2
done

if [ "\$BOOTED" -eq 0 ]; then
  echo "  ❌ ERROR: Container did not start within 60 seconds"
  echo ""
  echo "  ── Last 50 log lines ────────────────────────────────────────────"
  \$DCMD compose logs --tail=50 app 2>&1 | sed 's/^/     /' || true

  if [ "\$ROLLBACK_AVAILABLE" -eq 1 ]; then
    echo ""
    echo "  ── Rolling back to previous version ─────────────────────────────"
    \$DCMD compose down --remove-orphans 2>&1 | sed 's/^/     /' || true
    \$DCMD tag \$ROLLBACK_TAG ${IMAGE_NAME}:latest
    if \$DCMD compose up -d 2>&1 | sed 's/^/     /'; then
      echo "  ✅ Rollback complete — old version is live again"
      echo "  ⚠️  Fix the issue in your code then deploy again"
    else
      echo "  ❌ Rollback also failed — manual intervention needed"
      echo "     SSH in and run: docker compose up -d"
    fi
  else
    echo "  ⚠️  No rollback available (this was a fresh deploy)"
    echo "     Fix the issue and deploy again"
  fi
  exit 1
fi

echo "     ✅ Container started in \$((SECONDS - BOOT_START))s"
echo ""

# ── R9: Real health check — hit the actual port ───────────────────────────
echo "  ── R9: Health check on port $APP_PORT ───────────────────────────"
HEALTH_START=\$SECONDS
HEALTHY=0
for attempt in 1 2 3 4 5; do
  HTTP_CODE=\$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 5 \
    "http://localhost:$APP_PORT" 2>/dev/null || echo "000")

  if [ "\$HTTP_CODE" != "000" ] && [ "\$HTTP_CODE" != "502" ] && [ "\$HTTP_CODE" != "503" ]; then
    echo "     ✅ App responded with HTTP \$HTTP_CODE (attempt \$attempt)"
    HEALTHY=1
    break
  fi

  echo "     ⏳ Attempt \$attempt — HTTP \$HTTP_CODE — waiting 3s..."
  sleep 3
done

if [ "\$HEALTHY" -eq 0 ]; then
  echo "  ⚠️  WARNING: App did not respond on port $APP_PORT after 5 attempts"
  echo "     The container is running but the app may still be starting"
  echo "     Check logs with: ./deploy.sh logs"
  echo "     This is NOT a fatal error — deploy continues"
fi
echo ""

# ── R10: Container status ─────────────────────────────────────────────────
echo "  ── R10: Container status ─────────────────────────────────────────"
\$DCMD compose ps 2>&1 | sed 's/^/     /' || true
echo ""

# ── R11: Last 20 log lines ────────────────────────────────────────────────
echo "  ── R11: Last 20 log lines ────────────────────────────────────────"
\$DCMD compose logs --tail=20 app 2>&1 | sed 's/^/     /' || true
echo ""

# ── R12: Remove old images — keep only :latest and :rollback ─────────────
echo "  ── R12: Removing old images (keeping :latest and :rollback) ──────"
# Get all image IDs for this app
ALL_IDS=\$(\$DCMD images --format "{{.ID}} {{.Repository}}:{{.Tag}}" \
  | grep "^.\{0,\} ${IMAGE_NAME}:" \
  | awk '{print \$1}' || true)

KEEP_LATEST=\$(\$DCMD image inspect --format "{{.Id}}" ${IMAGE_NAME}:latest 2>/dev/null || echo "")
KEEP_ROLLBACK=\$(\$DCMD image inspect --format "{{.Id}}" ${IMAGE_NAME}:rollback 2>/dev/null || echo "")

REMOVED=0
for ID in \$ALL_IDS; do
  FULL_ID=\$(\$DCMD image inspect --format "{{.Id}}" \$ID 2>/dev/null || echo "")
  if [ "\$FULL_ID" = "\$KEEP_LATEST" ] || [ "\$FULL_ID" = "\$KEEP_ROLLBACK" ]; then
    continue
  fi
  echo "     Removing old image: \$ID"
  \$DCMD rmi -f \$ID 2>&1 | sed 's/^/     /' || true
  REMOVED=\$((REMOVED + 1))
done

# Also prune dangling (untagged) images
\$DCMD image prune -f 2>&1 | sed 's/^/     /' || true

echo "     ✅ Cleanup done — removed \$REMOVED old image(s)"
echo ""

# ── R13: Final disk usage ─────────────────────────────────────────────────
echo "  ── R13: Final disk usage ─────────────────────────────────────────"
df -h $SERVER_PATH | sed 's/^/     /'
echo ""
echo "  [REMOTE] ✅ All steps complete"

REMOTE

  local REMOTE_EXIT=$?

  if [ $REMOTE_EXIT -ne 0 ]; then
    print_summary
    step_err "DEPLOYMENT FAILED (remote exit $REMOTE_EXIT)"
    printf "   Check the output above — each step is labelled R1–R13\n"
    printf "   If rollback was available, old version is live again\n"
    printf "   Common causes:\n"
    printf "   - App crashed on startup            → check logs above\n"
    printf "   - Image name mismatch               → expected: %s\n" "$IMAGE_NAME"
    printf "   - Missing env vars in .env          → check .env on server\n"
    printf "   - Port %s already in use           → check: ssh in, netstat -tlnp\n\n" "$APP_PORT"
    exit 1
  fi

  print_summary
  printf "  ${GREEN}✅ Deployment complete!${NC}\n"
  [ -n "$DEPLOY_CLIENT" ] && printf "  ${DIM} Client           : %s${NC}\n" "$DEPLOY_CLIENT"
  printf "  ${DIM} Total deploy time : %ss${NC}\n\n" "$((SECONDS - PUSH_TOTAL_START))"
  printf "  ${BOLD}App URL :${NC} http://%s:%s\n\n" "$SERVER_IP" "$APP_PORT"
}

# ── Rollback ──────────────────────────────────────────────────────────────────
do_rollback() {
  print_header "Manual Rollback on $SERVER_IP"
  check_ssh

  step_start "Checking if rollback image exists on server..."
  local HAS_ROLLBACK
  HAS_ROLLBACK=$(remote "\
    if groups | grep -q docker 2>/dev/null; then DCMD=docker; else DCMD=\"sudo docker\"; fi; \
    \$DCMD image inspect ${IMAGE_NAME}:rollback &>/dev/null 2>&1 && echo yes || echo no" 2>/dev/null || echo no)

  if [ "$HAS_ROLLBACK" != "yes" ]; then
    step_err "ROLLBACK FAILED: No :rollback image found on server"
    printf "   A rollback image is created automatically during each deploy.\n"
    printf "   You need at least one successful deploy before rollback is available.\n"
    exit 1
  fi

  step_ok "Rollback image found"

  printf "  ${YELLOW}⚠️  This will replace the running app with the previous version.${NC}\n"
  printf "  Continue? (y/N): " >&2
  local confirm=""
  read confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    printf "  Aborted.\n\n"; exit 0
  fi

  printf "\n"

  remote bash << REMOTE
set -eo pipefail

if groups | grep -q docker 2>/dev/null; then DCMD=docker; else DCMD="sudo docker"; fi

echo "  [ROLLBACK] Starting manual rollback..."
echo ""

cd $SERVER_PATH || {
  echo "  ❌ ERROR: Could not cd into $SERVER_PATH"
  exit 1
}

echo "  ── Step 1: Stopping current containers ───────────────────────────"
\$DCMD compose down --remove-orphans 2>&1 | sed 's/^/     /' || true
echo "  ✅ Stopped"
echo ""

echo "  ── Step 2: Restoring :rollback as :latest ────────────────────────"
if ! \$DCMD tag ${IMAGE_NAME}:rollback ${IMAGE_NAME}:latest 2>&1 | sed 's/^/     /'; then
  echo "  ❌ ERROR: Could not tag rollback image as latest"
  exit 1
fi
echo "  ✅ Restored"
echo ""

echo "  ── Step 3: Starting restored containers ──────────────────────────"
if ! \$DCMD compose up -d 2>&1 | sed 's/^/     /'; then
  echo "  ❌ ERROR: Failed to start rollback containers"
  exit 1
fi
echo "  ✅ Started"
echo ""

echo "  ── Step 4: Verifying container is running ────────────────────────"
sleep 4
RUNNING=\$(\$DCMD compose ps 2>/dev/null | { grep -c "Up\|running" || true; })
if [ "\$RUNNING" -eq 0 ]; then
  echo "  ❌ ERROR: Rollback container is not running"
  \$DCMD compose logs --tail=30 app 2>&1 | sed 's/^/     /' || true
  exit 1
fi
echo "  ✅ Container is running"
echo ""

echo "  ── Step 5: Container status ──────────────────────────────────────"
\$DCMD compose ps 2>&1 | sed 's/^/     /' || true
echo ""
echo "  [ROLLBACK] ✅ Manual rollback complete"

REMOTE

  local ROLLBACK_EXIT=$?
  if [ $ROLLBACK_EXIT -ne 0 ]; then
    step_err "ROLLBACK FAILED (exit $ROLLBACK_EXIT)"
    printf "   Check the output above for the exact step that failed\n"
    exit 1
  fi

  print_summary
  printf "  ${GREEN}✅ Rollback complete — previous version is live${NC}\n"
  printf "  ${BOLD}App URL :${NC} http://%s:%s\n\n" "$SERVER_IP" "$APP_PORT"
}

# ── Restart ───────────────────────────────────────────────────────────────────
do_restart() {
  print_header "Restart on $SERVER_IP"
  check_ssh

  step_start "Restarting services..."
  printf "\n"

  remote bash << REMOTE
set -eo pipefail

if groups | grep -q docker 2>/dev/null; then DCMD=docker; else DCMD="sudo docker"; fi

echo "  [REMOTE] Docker command: \$DCMD"

cd $SERVER_PATH || {
  echo "  ❌ ERROR: Could not cd into $SERVER_PATH"
  exit 1
}

echo "  ── Stopping containers ───────────────────────────────────────────"
\$DCMD compose down --remove-orphans 2>&1 | sed 's/^/     /' || true
echo ""

echo "  ── Checking port $APP_PORT ───────────────────────────────────────"
CONFLICTING=\$(\$DCMD ps -q --filter "publish=$APP_PORT" 2>/dev/null || echo "")
if [ -n "\$CONFLICTING" ]; then
  echo "     Removing conflicting containers..."
  \$DCMD rm -f \$CONFLICTING 2>&1 | sed 's/^/     /' || true
else
  echo "     No port conflicts"
fi
echo ""

echo "  ── Starting services ─────────────────────────────────────────────"
if ! \$DCMD compose up -d 2>&1 | sed 's/^/     /'; then
  echo "  ❌ ERROR: docker compose up failed"
  echo "     Check your docker-compose.yml and .env on the server"
  exit 1
fi
echo ""

echo "  ── Polling for startup (max 60s) ─────────────────────────────────"
BOOT_START=\$SECONDS
BOOTED=0
while [ \$((SECONDS - BOOT_START)) -lt 60 ]; do
  RUNNING=\$(\$DCMD compose ps 2>/dev/null | { grep -c "Up\|running" || true; })
  if [ "\$RUNNING" -gt 0 ]; then BOOTED=1; break; fi
  echo "     ⏳ \$((SECONDS - BOOT_START))s — waiting..."
  sleep 2
done

if [ "\$BOOTED" -eq 0 ]; then
  echo "  ❌ ERROR: Container did not start within 60 seconds after restart"
  \$DCMD compose logs --tail=50 2>&1 | sed 's/^/     /' || true
  exit 1
fi

echo "     ✅ Container started in \$((SECONDS - BOOT_START))s"
echo ""
echo "  ── Container status ──────────────────────────────────────────────"
\$DCMD compose ps 2>&1 | sed 's/^/     /' || true
echo ""
echo "  ── Last 20 log lines ─────────────────────────────────────────────"
\$DCMD compose logs --tail=20 app 2>&1 | sed 's/^/     /' || true

REMOTE

  local REMOTE_EXIT=$?
  if [ $REMOTE_EXIT -ne 0 ]; then
    step_err "RESTART FAILED — check logs above for which step failed"
    exit 1
  fi

  step_ok "Restart complete"
  printf "  ${BOLD}App URL :${NC} http://%s:%s\n\n" "$SERVER_IP" "$APP_PORT"
}

# ── Stop ──────────────────────────────────────────────────────────────────────
do_stop() {
  print_header "Stop on $SERVER_IP"
  check_ssh

  step_start "Stopping all containers..."

  remote bash << REMOTE
if groups | grep -q docker 2>/dev/null; then DCMD=docker; else DCMD="sudo docker"; fi

cd $SERVER_PATH || {
  echo "  ❌ ERROR: Could not cd into $SERVER_PATH"
  exit 1
}

\$DCMD compose down --remove-orphans 2>&1 | sed 's/^/     /'
echo ""
echo "  ── Remaining containers on server ────────────────────────────────"
\$DCMD ps 2>&1 | sed 's/^/     /'

REMOTE

  step_ok "All containers stopped"
}

# ── Logs ──────────────────────────────────────────────────────────────────────
do_logs() {
  print_header "Logs from $SERVER_IP"
  check_ssh

  printf "${DIM}  Tailing logs... Ctrl+C to exit${NC}\n\n"

  remote bash << REMOTE
if groups | grep -q docker 2>/dev/null; then DCMD=docker; else DCMD="sudo docker"; fi

cd $SERVER_PATH || {
  echo "  ❌ ERROR: Could not cd into $SERVER_PATH"
  exit 1
}

\$DCMD compose logs -f app

REMOTE
}

# ── Local ─────────────────────────────────────────────────────────────────────
do_local() {
  print_header "Local Test"

  step_start "Building image locally..."
  docker build -t "$IMAGE_NAME:latest" . || {
    step_err "LOCAL BUILD FAILED: docker build exited with an error"
    exit 1
  }
  step_ok "Local image built"

  step_start "Starting local compose..."
  docker compose -f docker-compose.local.yml up || {
    step_err "LOCAL START FAILED: docker compose up exited with an error"
    exit 1
  }
}

# ── Router ────────────────────────────────────────────────────────────────────
case "$CMD" in
  build)    do_build ;;
  push)     do_push ;;
  rollback) do_rollback ;;
  restart)  do_restart ;;
  stop)     do_stop ;;
  logs)     do_logs ;;
  local)    do_local ;;
  client)
    case "$2" in
      --list)   do_client_list ;;
      --add)    do_client_add ;;
      --remove) do_client_remove "$@" ;;
      *)
        printf "Usage: ./deploy.sh client [--list | --add | --remove NAME]\n"
        exit 1
        ;;
    esac
    ;;
  *)
    printf "\nUsage: ./deploy.sh [COMMAND]\n\n"
    printf "  build              Build image + export tar locally\n"
    printf "  push               Build + upload + deploy to server\n"
    printf "  push --client NAME Deploy for a specific client\n"
    printf "  rollback           Restore previous :rollback image on server\n"
    printf "  restart            Restart containers on server\n"
    printf "  stop               Stop containers on server\n"
    printf "  logs               Tail live server logs\n"
    printf "  local              Run locally for testing\n"
    printf "  client --list      List all clients in deploy.config.sh\n"
    printf "  client --add       Add a new client\n"
    printf "  client --remove N  Remove a client\n\n"
    exit 1
    ;;
esac
