#!/bin/bash
# ── Universal Next.js Deploy Script ──────────────────────────────────────────
# Version: 2.1.0
# Usage:
#   ./deploy.sh                        → build image + export tar
#   ./deploy.sh push                   → build + upload + restart
#   ./deploy.sh push --client GCKC     → deploy for specific client
#   ./deploy.sh restart                → just restart on server
#   ./deploy.sh stop                   → stop everything on server
#   ./deploy.sh logs                   → tail server logs
#   ./deploy.sh local                  → run locally for testing
#   ./deploy.sh client --list          → list all clients in .env
#   ./deploy.sh client --add           → add new client to .env
#   ./deploy.sh client --remove NAME   → remove client from .env
# ─────────────────────────────────────────────────────────────────────────────

DEPLOY_VERSION="2.1.0"

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
ts()         { date '+%H:%M:%S'; }
elapsed()    { echo "$((SECONDS - STEP_START))s"; }
step_start() { STEP_START=$SECONDS; printf "${CYAN}[$(ts)]${NC} ${BOLD}▶ %s${NC}\n" "$1"; }
step_ok()    { printf "${GREEN}[$(ts)]${NC} ${GREEN}✅ %s${NC} ${DIM}($(elapsed))${NC}\n\n" "$1"; }
step_warn()  { printf "${YELLOW}[$(ts)]${NC} ${YELLOW}⚠️  %s${NC}\n" "$1"; }
step_err()   { printf "${RED}[$(ts)]${NC} ${RED}❌ %s${NC}\n" "$1"; }
info()       { printf "${DIM}[$(ts)]   %s${NC}\n" "$1"; }

print_header() {
  printf "\n${BOLD}${BLUE}══════════════════════════════════════════${NC}\n"
  printf "${BOLD}${BLUE}  %s — %s${NC}\n" "$APP_NAME" "$1"
  printf "${BOLD}${BLUE}══════════════════════════════════════════${NC}\n"
  printf "${DIM}  Version : %s${NC}\n" "$DEPLOY_VERSION"
  printf "${DIM}  Started : %s${NC}\n\n" "$(date '+%Y-%m-%d %H:%M:%S')"
}

print_divider() { printf "${DIM}  ──────────────────────────────────────────${NC}\n"; }

print_summary() {
  printf "\n${BOLD}${MAGENTA}══════════════════════════════════════════${NC}\n"
  printf "${BOLD}${MAGENTA}  Summary${NC}\n"
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

# ── Load server password from Keychain ───────────────────────────────────────
SERVER_PASS=$(security find-generic-password -a "$SERVER_USER" -s "deploy-${APP_NAME}-server" -w 2>/dev/null || echo "")
if [ -z "$SERVER_PASS" ]; then
  printf "${RED}❌ Server password not found in Keychain.${NC}\n"
  printf "   Fix: cd your-project && setup-deploy --update-secrets\n"
  exit 1
fi

# ── Parse arguments ───────────────────────────────────────────────────────────
CMD="${1:-build}"
CLIENT_NAME=""

# Parse --client flag
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
    sshpass -p "$SERVER_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 "$SERVER_USER@$SERVER_IP" "$@"
  else
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 "$SERVER_USER@$SERVER_IP" "$@"
  fi
}

push_file_progress() {
  local src="$1"
  local dst="$2"
  local filename=$(basename "$src")
  local filesize=$(du -sh "$src" 2>/dev/null | cut -f1)

  info "  File   : $filename"
  info "  Size   : $filesize"
  info "  Dest   : $SERVER_USER@$SERVER_IP:$dst"
  printf "\n"

  local TRANSFER_START=$SECONDS

  if command -v rsync &>/dev/null; then
    info "Using rsync (with live progress)..."
    if command -v sshpass &>/dev/null && [ -n "$SERVER_PASS" ]; then
      sshpass -p "$SERVER_PASS" rsync -avz --progress \
        -e "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15" \
        "$src" "$SERVER_USER@$SERVER_IP:$dst" || {
        step_err "Failed to transfer $filename"
        printf "   Check: server is reachable, disk space is available, path exists\n"
        exit 1
      }
    else
      rsync -avz --progress \
        -e "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15" \
        "$src" "$SERVER_USER@$SERVER_IP:$dst" || {
        step_err "Failed to transfer $filename"
        exit 1
      }
    fi
  else
    info "rsync not found — using scp..."
    if command -v sshpass &>/dev/null && [ -n "$SERVER_PASS" ]; then
      sshpass -p "$SERVER_PASS" scp -o StrictHostKeyChecking=no \
        -o ConnectTimeout=15 "$src" "$SERVER_USER@$SERVER_IP:$dst" || {
        step_err "Failed to transfer $filename via scp"
        exit 1
      }
    else
      scp -o StrictHostKeyChecking=no \
        -o ConnectTimeout=15 "$src" "$SERVER_USER@$SERVER_IP:$dst" || {
        step_err "Failed to transfer $filename via scp"
        exit 1
      }
    fi
  fi

  local transfer_elapsed=$((SECONDS - TRANSFER_START))
  local bytes=$(file_bytes "$src")
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
    step_err "Cannot connect to $SERVER_IP"
    printf "   Possible reasons:\n"
    printf "   - Wrong IP address: %s\n" "$SERVER_IP"
    printf "   - Wrong username: %s\n" "$SERVER_USER"
    printf "   - Wrong password (update with: setup-deploy --update-secrets)\n"
    printf "   - Server is offline or unreachable\n"
    printf "   - SSH port blocked by firewall\n"
    exit 1
  fi
}

# ── Validate docker-compose.yml has correct image name ───────────────────────
check_compose_image() {
  if [ ! -f "docker-compose.yml" ]; then
    step_err "docker-compose.yml not found in current directory"
    printf "   Make sure docker-compose.yml exists in your project root\n"
    exit 1
  fi
  if ! grep -q "$IMAGE_NAME" docker-compose.yml; then
    step_err "Image name '$IMAGE_NAME' not found in docker-compose.yml"
    printf "   Auto-fix:  setup-deploy --fix\n"
    printf "   Or manually ensure docker-compose.yml contains:  image: %s\n" "$IMAGE_NAME"
    exit 1
  fi
  if ! grep -qE 'ports:' docker-compose.yml; then
    step_warn "No 'ports:' section found in docker-compose.yml"
    printf "   Without a ports mapping, the app will not be accessible from outside the container.\n"
    printf "   Expected something like:\n"
    printf "       ports:\n"
    printf "         - \"%s:3000\"\n" "$APP_PORT"
    printf "   Continue anyway? (y/N): " >&2
    read _compose_confirm
    if [ "$_compose_confirm" != "y" ] && [ "$_compose_confirm" != "Y" ]; then
      printf "  Aborted. Fix docker-compose.yml and try again.\n"
      exit 1
    fi
  fi
}

# ── Client management helpers ─────────────────────────────────────────────────

# Get all client names from .env (commented or not)
get_env_clients() {
  grep -E '^#?\s*CLIENT_ID=' .env 2>/dev/null | \
    sed 's/^#\s*//' | \
    sed 's/CLIENT_ID=//' | \
    sed 's/#.*//' | \
    tr -d ' ' | \
    sort -u
}

# Get URL for a client from .env (commented or not)
get_client_url() {
  local client="$1"
  # Find CLIENT_ID line for this client, then get the URL line above it
  grep -n -E "^#?\s*CLIENT_ID=\s*${client}\s*$" .env 2>/dev/null | head -1 | while IFS=: read -r lineno rest; do
    if [ -n "$lineno" ] && [ "$lineno" -gt 1 ]; then
      url_line=$(sed -n "$((lineno-1))p" .env)
      echo "$url_line" | sed 's/^#\s*//' | sed 's/NEXT_PUBLIC_API_BASE_URL=//' | sed 's/#.*//' | tr -d ' '
    fi
  done
}

# Build clean .env for a specific client
build_client_env() {
  local client="$1"
  local env_file=".env"
  local tmp_env=$(mktemp)

  # Get client URL
  local client_url
  client_url=$(get_client_url "$client")

  if [ -z "$client_url" ]; then
    step_err "Client '$client' not found in .env"
    printf "   Run: ./deploy.sh client --list   to see available clients\n"
    rm -f "$tmp_env"
    exit 1
  fi

  # Write non-client lines first (skip all CLIENT_ID and API_BASE_URL lines)
  grep -vE '^#?\s*(NEXT_PUBLIC_API_BASE_URL|CLIENT_ID)=' "$env_file" | \
    grep -v '^#.*#' | \
    sed 's/[[:space:]]*#[^=]*$//' \
    > "$tmp_env"

  # Add clean client config at bottom
  printf "\nNEXT_PUBLIC_API_BASE_URL=%s\n" "$client_url" >> "$tmp_env"
  printf "CLIENT_ID=%s\n" "$client" >> "$tmp_env"

  echo "$tmp_env"
}

# ── Client commands ───────────────────────────────────────────────────────────
do_client_list() {
  if [ ! -f ".env" ]; then
    step_err "No .env file found in current directory"
    exit 1
  fi

  printf "\n${BOLD}${CYAN}  Available clients in .env:${NC}\n\n"

  local clients
  clients=$(get_env_clients)

  if [ -z "$clients" ]; then
    printf "  ${DIM}No clients found. Add one with: ./deploy.sh client --add${NC}\n\n"
    return
  fi

  local i=1
  while IFS= read -r client; do
    local url
    url=$(get_client_url "$client")
    printf "  ${BOLD}%d. %-15s${NC} ${DIM}→ %s${NC}\n" "$i" "$client" "$url"
    i=$((i+1))
  done <<< "$clients"
  printf "\n"
}

do_client_add() {
  if [ ! -f ".env" ]; then
    step_err "No .env file found in current directory"
    exit 1
  fi

  printf "\n${BOLD}${CYAN}  Add New Client${NC}\n\n"

  # Client name
  while true; do
    printf "  ? Client name (e.g. GCKC, DARA, Samarth): " >&2
    read client_name
    if [ -z "$client_name" ]; then
      printf "  ❌ Client name cannot be empty.\n" >&2
      continue
    fi
    if ! echo "$client_name" | grep -qE '^[a-zA-Z0-9_-]+$'; then
      printf "  ❌ No spaces or special characters allowed.\n" >&2
      continue
    fi
    # Check duplicate
    if get_env_clients | grep -qx "$client_name"; then
      printf "  ❌ Client '%s' already exists.\n" "$client_name" >&2
      continue
    fi
    break
  done

  # API URL
  while true; do
    printf "  ? API Base URL for %s: " "$client_name" >&2
    read client_url
    if [ -z "$client_url" ]; then
      printf "  ❌ URL cannot be empty.\n" >&2
      continue
    fi
    if ! echo "$client_url" | grep -qE '^https?://'; then
      printf "  ❌ URL must start with http:// or https://\n" >&2
      printf "     You entered: %s\n" "$client_url" >&2
      continue
    fi
    break
  done

  # Add to .env
  printf "\n# NEXT_PUBLIC_API_BASE_URL=%s  # for %s\n# CLIENT_ID=%s\n" \
    "$client_url" "$client_name" "$client_name" >> .env

  printf "\n"
  success() { printf "${GREEN}  ✅ %s${NC}\n" "$1"; }
  success "Client '$client_name' added to .env (commented by default)"
  printf "  ${DIM}Deploy with: ./deploy.sh push --client %s${NC}\n\n" "$client_name"
}

do_client_remove() {
  local client="$2"
  if [ -z "$client" ]; then
    printf "  Usage: ./deploy.sh client --remove CLIENT_NAME\n"
    exit 1
  fi

  if [ ! -f ".env" ]; then
    step_err "No .env file found"
    exit 1
  fi

  if ! get_env_clients | grep -qx "$client"; then
    step_err "Client '$client' not found in .env"
    do_client_list
    exit 1
  fi

  printf "\n  ${YELLOW}⚠️  Remove client '%s' from .env?${NC}\n" "$client"
  printf "  This will permanently delete its URL and CLIENT_ID lines.\n"
  printf "  Confirm? (y/N): " >&2
  read confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    printf "  Aborted.\n\n"
    exit 0
  fi

  # Remove lines containing this client
  local tmp=$(mktemp)
  grep -v "CLIENT_ID=${client}" .env | grep -v "CLIENT_ID= *${client}" > "$tmp"
  mv "$tmp" .env

  printf "${GREEN}  ✅ Client '%s' removed from .env${NC}\n\n" "$client"
}

# ── Build ─────────────────────────────────────────────────────────────────────
do_build() {
  local BUILD_TOTAL_START=$SECONDS
  print_header "Build"

  # Check Dockerfile exists
  if [ ! -f "Dockerfile" ]; then
    step_err "Dockerfile not found in current directory"
    printf "   Make sure you are running this from your project root folder\n"
    exit 1
  fi

  step_start "Building Docker image for linux/amd64..."
  info "  Image name : $IMAGE_NAME:latest"
  info "  Platform   : linux/amd64"
  printf "\n"

  # Get DATABASE_URL for build arg
  local BUILD_DB_URL=""
  if [ -n "$DB_CLIENTS" ]; then
    first_client=$(echo "$DB_CLIENTS" | awk '{print $1}')
    BUILD_DB_URL=$(security find-generic-password -a "$SERVER_USER" -s "deploy-${APP_NAME}-db-${first_client}-url" -w 2>/dev/null || echo "")
  else
    BUILD_DB_URL=$(security find-generic-password -a "$SERVER_USER" -s "deploy-${APP_NAME}-dburl" -w 2>/dev/null || echo "")
  fi

  set -o pipefail
  docker build --platform linux/amd64 -t "$IMAGE_NAME:latest" \
    ${BUILD_DB_URL:+--build-arg DATABASE_URL="$BUILD_DB_URL"} \
    . 2>&1 | \
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
    step_err "Docker build FAILED (exit $BUILD_EXIT)"
    printf "   Fix the build error above, then run: ./deploy.sh push\n"
    exit 1
  fi
  step_ok "Docker image built successfully"

  step_start "Checking image details..."
  printf "\n"
  docker images "$IMAGE_NAME:latest" --format "  ID:      {{.ID}}\n  Size:    {{.Size}}\n  Created: {{.CreatedAt}}"
  printf "\n"
  step_ok "Image info retrieved"

  step_start "Exporting image to $TAR_FILE..."
  info "  This may take 1-3 minutes..."
  printf "\n"

  EXPORT_START=$SECONDS
  docker save "$IMAGE_NAME:latest" | gzip > "$TAR_FILE" || {
    step_err "Failed to export Docker image to $TAR_FILE"
    printf "   Check disk space: df -h .\n"
    exit 1
  }
  EXPORT_TIME=$((SECONDS - EXPORT_START))
  SIZE=$(du -sh "$TAR_FILE" | cut -f1)

  printf "\n"
  info "  Output file : $TAR_FILE"
  info "  File size   : $SIZE"
  info "  Export time : ${EXPORT_TIME}s"
  printf "\n"
  step_ok "Image exported successfully"

  print_summary
  printf "  ${GREEN}✅ Image built and exported${NC}\n"
  printf "  ${DIM}   Total build time : %ss${NC}\n\n" "$((SECONDS - BUILD_TOTAL_START))"
  printf "  To deploy:  ./deploy.sh push\n\n"
}

# ── Push ──────────────────────────────────────────────────────────────────────
do_push() {
  local PUSH_TOTAL_START=$SECONDS

  # ── Determine client ────────────────────────────────────────────────────────
  local DEPLOY_CLIENT=""
  local ENV_FILE=".env"
  local CLEAN_ENV_FILE=""

  if [ ! -f ".env" ]; then
    step_err ".env file not found in current directory"
    printf "   Create a .env file with your environment variables first\n"
    exit 1
  fi

  local available_clients
  available_clients=$(get_env_clients)

  if [ -n "$available_clients" ]; then
    if [ -n "$CLIENT_NAME" ]; then
      # --client flag provided
      DEPLOY_CLIENT="$CLIENT_NAME"
    else
      # Ask user to pick
      printf "\n${BOLD}${CYAN}  Available clients found in .env:${NC}\n\n"
      local i=1
      local client_list=()
      while IFS= read -r c; do
        local curl
        curl=$(get_client_url "$c")
        printf "  ${BOLD}%d. %-15s${NC} ${DIM}%s${NC}\n" "$i" "$c" "$curl"
        client_list+=("$c")
        i=$((i+1))
      done <<< "$available_clients"
      printf "\n"
      printf "  ? Enter client number or name (or press Enter to deploy as-is): " >&2
      read client_input

      if [ -n "$client_input" ]; then
        # Check if number
        if echo "$client_input" | grep -qE '^[0-9]+$'; then
          DEPLOY_CLIENT="${client_list[$((client_input-1))]}"
        else
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

  # ── Validate docker-compose.yml before building ────────────────────────────
  check_compose_image

  do_build
  print_divider

  if ! command -v sshpass &>/dev/null; then
    step_warn "sshpass not found — will use SSH keys instead"
    info "Install with: brew install hudochenkov/sshpass/sshpass"
    printf "\n"
  fi

  check_ssh
  print_divider

  step_start "Creating folder on server: $SERVER_PATH"
  remote "mkdir -p $SERVER_PATH && echo 'Folder ready'" || {
    step_err "Failed to create folder $SERVER_PATH on server"
    printf "   Check server path and SSH permissions\n"
    exit 1
  }
  step_ok "Remote folder ready"

  step_start "Checking remote disk space..."
  printf "\n"
  remote "df -h $SERVER_PATH 2>/dev/null | awk 'NR==1{print \"  \"\$0} NR==2{print \"  \"\$0}'" || true
  printf "\n"
  step_ok "Disk space checked"

  print_divider
  printf "${BOLD}[$(ts)] Transferring files to server...${NC}\n\n"

  step_start "Uploading Docker image tar..."
  push_file_progress "$TAR_FILE" "$SERVER_PATH/"
  step_ok "Docker image tar uploaded"

  step_start "Uploading docker-compose.yml..."
  push_file_progress "docker-compose.yml" "$SERVER_PATH/"
  step_ok "docker-compose.yml uploaded"

  step_start "Uploading .env${DEPLOY_CLIENT:+ (for $DEPLOY_CLIENT)}..."
  push_file_progress "$ENV_FILE" "$SERVER_PATH/.env"
  step_ok ".env uploaded"

  # Cleanup temp env file
  [ -n "$CLEAN_ENV_FILE" ] && rm -f "$CLEAN_ENV_FILE"

  step_start "Verifying files on server..."
  printf "\n"
  remote "ls -lh $SERVER_PATH/ | awk '{print \"  \"\$0}'" || true
  printf "\n"
  step_ok "Files verified"
  print_divider

  printf "${BOLD}[$(ts)] Loading image and restarting on server...${NC}\n\n"

  remote bash << REMOTE
    set -eo pipefail

    echo "  [REMOTE] Working in: $SERVER_PATH"
    cd $SERVER_PATH

    echo ""
    echo "  ── R1: Stopping existing containers ───────────────────"
    docker compose down --remove-orphans 2>&1 | sed 's/^/  /' || true

    echo ""
    echo "  ── R2: Removing known containers ──────────────────────"
    docker rm -f ${APP_NAME}_app redis_container 2>&1 | sed 's/^/  /' || true

    echo ""
    echo "  ── R3: Checking port conflicts on $APP_PORT ────────────"
    CONFLICTING=\$(docker ps -q --filter "publish=$APP_PORT")
    if [ -n "\$CONFLICTING" ]; then
      echo "  Removing conflicting containers: \$CONFLICTING"
      docker rm -f \$CONFLICTING 2>&1 | sed 's/^/  /'
    else
      echo "  No port conflicts on $APP_PORT"
    fi

    echo ""
    echo "  ── R4: Loading Docker image ────────────────────────────"
    if [ ! -f "$TAR_FILE" ]; then
      echo "  ERROR: $TAR_FILE not found on server"
      exit 1
    fi
    LOAD_START=\$SECONDS
    docker load -i $TAR_FILE
    echo "  Load time: \$((SECONDS - LOAD_START))s"

    echo ""
    echo "  ── R5: Available images ────────────────────────────────"
    docker images | grep -E "REPOSITORY|$IMAGE_NAME" | sed 's/^/  /'

    echo ""
    echo "  ── R6: Starting services ───────────────────────────────"
    docker compose up -d

    echo ""
    echo "  ── R7: Waiting for containers (8s) ─────────────────────"
    sleep 8

    echo ""
    echo "  ── R8: Container status ────────────────────────────────"
    docker compose ps 2>&1 | sed 's/^/  /'

    echo ""
    echo "  ── R9: Verifying containers are running ────────────────"
    RUNNING=\$(docker compose ps 2>/dev/null | { grep -c " Up \| running " || true; })
    if [ "\$RUNNING" -eq 0 ]; then
      echo "  ERROR: No containers are running after startup."
      echo ""
      echo "  ── Last 50 log lines ───────────────────────────────────"
      docker compose logs --tail=50 2>&1 | sed 's/^/  /' || true
      exit 1
    fi
    echo "  Running containers: \$RUNNING"

    echo ""
    echo "  ── R10: Last 20 log lines ──────────────────────────────"
    docker compose logs --tail=20 app 2>&1 | sed 's/^/  /' || true

    echo ""
    echo "  ── R11: Cleaning old images ────────────────────────────"
    docker image prune -f 2>&1 | sed 's/^/  /'

    echo ""
    echo "  ── R12: Final disk usage ───────────────────────────────"
    df -h $SERVER_PATH | sed 's/^/  /'

    echo ""
    echo "  [REMOTE] All steps complete."
REMOTE
  REMOTE_EXIT=$?

  if [ $REMOTE_EXIT -ne 0 ]; then
    print_summary
    step_err "Deployment FAILED (remote exit $REMOTE_EXIT)"
    printf "  Check the output above for the exact error.\n"
    printf "  Common causes:\n"
    printf "   - Container crashed on startup — check logs above\n"
    printf "   - Image name mismatch in docker-compose.yml (expected: %s)\n" "$IMAGE_NAME"
    printf "   - Missing or wrong environment variables in .env\n"
    printf "   - Port %s already in use on server\n\n" "$APP_PORT"
    exit 1
  fi

  print_summary
  printf "  ${GREEN}✅ Deployment complete!${NC}\n"
  [ -n "$DEPLOY_CLIENT" ] && printf "  ${DIM}   Client : %s${NC}\n" "$DEPLOY_CLIENT"
  printf "  ${DIM}   Total deploy time : %ss${NC}\n\n" "$((SECONDS - PUSH_TOTAL_START))"
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
    cd $SERVER_PATH

    echo "  ── Stopping containers ─────────────────────────────────"
    docker compose down --remove-orphans 2>&1 | sed 's/^/  /' || true

    echo ""
    echo "  ── Removing known containers ───────────────────────────"
    docker rm -f ${APP_NAME}_app redis_container 2>&1 | sed 's/^/  /' || true

    echo ""
    echo "  ── Checking port $APP_PORT ──────────────────────────────"
    CONFLICTING=\$(docker ps -q --filter "publish=$APP_PORT")
    if [ -n "\$CONFLICTING" ]; then
      docker rm -f \$CONFLICTING 2>&1 | sed 's/^/  /'
    else
      echo "  No port conflicts"
    fi

    echo ""
    echo "  ── Starting services ───────────────────────────────────"
    docker compose up -d

    echo ""
    sleep 8
    echo "  ── Verifying containers are running ────────────────────"
    RUNNING=\$(docker compose ps 2>/dev/null | { grep -c " Up \| running " || true; })
    if [ "\$RUNNING" -eq 0 ]; then
      echo "  ERROR: No containers are running after restart."
      docker compose logs --tail=50 2>&1 | sed 's/^/  /' || true
      exit 1
    fi
    echo "  Running containers: \$RUNNING"

    echo ""
    echo "  ── Container status ────────────────────────────────────"
    docker compose ps 2>&1 | sed 's/^/  /'

    echo ""
    echo "  ── Last 20 log lines ───────────────────────────────────"
    docker compose logs --tail=20 app 2>&1 | sed 's/^/  /' || true
REMOTE
  REMOTE_EXIT=$?

  if [ $REMOTE_EXIT -ne 0 ]; then
    step_err "Restart FAILED — check logs above"
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
    cd $SERVER_PATH
    docker compose down --remove-orphans 2>&1 | sed 's/^/  /'
    echo ""
    echo "  ── Remaining containers ────────────────────────────────"
    docker ps 2>&1 | sed 's/^/  /'
REMOTE
  step_ok "All containers stopped"
}

# ── Logs ──────────────────────────────────────────────────────────────────────
do_logs() {
  print_header "Logs from $SERVER_IP"
  check_ssh
  printf "${DIM}  Tailing logs... Ctrl+C to exit${NC}\n\n"
  remote "cd $SERVER_PATH && docker compose logs -f app"
}

# ── Local ─────────────────────────────────────────────────────────────────────
do_local() {
  print_header "Local Test"
  step_start "Building image locally..."
  docker build -t "$IMAGE_NAME:latest" .
  step_ok "Local image built"
  step_start "Starting local compose..."
  docker compose -f docker-compose.local.yml up
}

# ── Router ────────────────────────────────────────────────────────────────────
case "$CMD" in
  build)   do_build   ;;
  push)    do_push    ;;
  restart) do_restart ;;
  stop)    do_stop    ;;
  logs)    do_logs    ;;
  local)   do_local   ;;
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
    printf "Usage: ./deploy.sh [build|push|restart|stop|logs|local|client]\n"
    printf "       ./deploy.sh push --client GCKC\n"
    printf "       ./deploy.sh client --list\n"
    printf "       ./deploy.sh client --add\n"
    printf "       ./deploy.sh client --remove NAME\n"
    exit 1
    ;;
esac
