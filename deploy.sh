#!/bin/bash
# ── Universal Next.js Deploy Script ──────────────────────────────────────────
# Version: 1.0.0
# Usage:
#   ./deploy.sh           → build image + export tar
#   ./deploy.sh push      → build + export + copy to server + restart
#   ./deploy.sh restart   → just restart on server (no rebuild)
#   ./deploy.sh stop      → stop everything on server
#   ./deploy.sh logs      → tail server logs
#   ./deploy.sh local     → run locally for testing
# ─────────────────────────────────────────────────────────────────────────────

set -e

DEPLOY_VERSION="1.0.0"

# ── Load config ───────────────────────────────────────────────────────────────
CONFIG_FILE="$(dirname "$0")/deploy.config.sh"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "❌ deploy.config.sh not found."
  echo "   Run: setup-deploy"
  exit 1
fi
source "$CONFIG_FILE"

# ── Load secrets from Keychain ────────────────────────────────────────────────
SERVER_PASS=$(security find-generic-password -a "$SERVER_USER" -s "deploy-${APP_NAME}-server" -w 2>/dev/null || echo "")
DATABASE_URL=$(security find-generic-password -a "$SERVER_USER" -s "deploy-${APP_NAME}-dburl" -w 2>/dev/null || echo "")

if [ -z "$SERVER_PASS" ]; then
  echo "❌ Server password not found in Keychain."
  echo "   Run: setup-deploy --update-secrets"
  exit 1
fi

if [ -z "$DATABASE_URL" ]; then
  echo "❌ Database URL not found in Keychain."
  echo "   Run: setup-deploy --update-secrets"
  exit 1
fi

CMD="${1:-build}"

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

step_start() { STEP_START=$SECONDS; echo -e "${CYAN}[$(ts)]${NC} ${BOLD}▶ $1${NC}"; }
step_ok()    { echo -e "${GREEN}[$(ts)]${NC} ${GREEN}✅ $1${NC} ${DIM}($(elapsed))${NC}"; echo ""; }
step_warn()  { echo -e "${YELLOW}[$(ts)]${NC} ${YELLOW}⚠️  $1${NC}"; }
step_err()   { echo -e "${RED}[$(ts)]${NC} ${RED}❌ $1${NC}"; }
info()       { echo -e "${DIM}[$(ts)]   $1${NC}"; }

print_header() {
  echo ""
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════${NC}"
  echo -e "${BOLD}${BLUE}  $APP_NAME — $1${NC}"
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════${NC}"
  echo -e "${DIM}  Version : $DEPLOY_VERSION${NC}"
  echo -e "${DIM}  Started : $(date '+%Y-%m-%d %H:%M:%S')${NC}"
  echo ""
}

print_divider() { echo -e "${DIM}  ──────────────────────────────────────────${NC}"; }

print_summary() {
  echo ""
  echo -e "${BOLD}${MAGENTA}══════════════════════════════════════════${NC}"
  echo -e "${BOLD}${MAGENTA}  Summary${NC}"
  echo -e "${BOLD}${MAGENTA}══════════════════════════════════════════${NC}"
}

# ── OS-safe file size ─────────────────────────────────────────────────────────
file_bytes() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    stat -f%z "$1" 2>/dev/null || echo 0
  else
    stat -c%s "$1" 2>/dev/null || echo 0
  fi
}

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
  echo ""

  local TRANSFER_START=$SECONDS

  if command -v rsync &>/dev/null; then
    info "Using rsync (with live progress)..."
    if command -v sshpass &>/dev/null && [ -n "$SERVER_PASS" ]; then
      sshpass -p "$SERVER_PASS" rsync -avz --progress \
        -e "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15" \
        "$src" "$SERVER_USER@$SERVER_IP:$dst"
    else
      rsync -avz --progress \
        -e "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15" \
        "$src" "$SERVER_USER@$SERVER_IP:$dst"
    fi
  else
    info "rsync not found — using scp..."
    if command -v sshpass &>/dev/null && [ -n "$SERVER_PASS" ]; then
      sshpass -p "$SERVER_PASS" scp -o StrictHostKeyChecking=no \
        -o ConnectTimeout=15 "$src" "$SERVER_USER@$SERVER_IP:$dst"
    else
      scp -o StrictHostKeyChecking=no \
        -o ConnectTimeout=15 "$src" "$SERVER_USER@$SERVER_IP:$dst"
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
    step_err "Cannot connect to $SERVER_IP — check credentials or network"
    exit 1
  fi
}

# ── Commands ──────────────────────────────────────────────────────────────────

do_build() {
  local BUILD_TOTAL_START=$SECONDS
  print_header "Build"

  step_start "Building Docker image for linux/amd64..."
  info "  Image name : $IMAGE_NAME:latest"
  info "  Platform   : linux/amd64"
  echo ""

  set -o pipefail
  docker build --platform linux/amd64 -t "$IMAGE_NAME:latest" \
    --build-arg DATABASE_URL="$DATABASE_URL" \
    . 2>&1 | \
    while IFS= read -r line; do
      if echo "$line" | grep -qiE "^(#[0-9]|Step [0-9])"; then
        echo -e "  ${CYAN}${line}${NC}"
      elif echo "$line" | grep -qiE "error|failed|cannot|denied"; then
        echo -e "  ${RED}${line}${NC}"
      elif echo "$line" | grep -qiE "warn|warning"; then
        echo -e "  ${YELLOW}${line}${NC}"
      elif echo "$line" | grep -qiE "successfully|complete|done|cached"; then
        echo -e "  ${GREEN}${line}${NC}"
      else
        echo -e "  ${DIM}${line}${NC}"
      fi
    done
  local BUILD_EXIT=$?
  set +o pipefail

  if [ $BUILD_EXIT -ne 0 ]; then
    step_err "Docker build FAILED (exit $BUILD_EXIT)"
    exit 1
  fi
  step_ok "Docker image built successfully"

  step_start "Checking image details..."
  echo ""
  docker images "$IMAGE_NAME:latest" --format "  ID:      {{.ID}}\n  Size:    {{.Size}}\n  Created: {{.CreatedAt}}"
  echo ""
  step_ok "Image info retrieved"

  step_start "Exporting image to $TAR_FILE..."
  info "  This may take 1-3 minutes depending on image size..."
  echo ""

  EXPORT_START=$SECONDS
  docker save "$IMAGE_NAME:latest" | gzip > "$TAR_FILE"
  EXPORT_TIME=$((SECONDS - EXPORT_START))
  SIZE=$(du -sh "$TAR_FILE" | cut -f1)

  echo ""
  info "  Output file : $TAR_FILE"
  info "  File size   : $SIZE"
  info "  Export time : ${EXPORT_TIME}s"
  echo ""
  step_ok "Image exported successfully"

  print_summary
  echo -e "  ${GREEN}✅ Image built and exported${NC}"
  echo -e "  ${DIM}   Total build time : $((SECONDS - BUILD_TOTAL_START))s${NC}"
  echo ""
  echo "  To deploy:  ./deploy.sh push"
  echo ""
}

do_push() {
  local PUSH_TOTAL_START=$SECONDS
  print_header "Push to $SERVER_IP"

  do_build
  print_divider

  if ! command -v sshpass &>/dev/null; then
    step_warn "sshpass not found — will use SSH keys instead."
    info "Install with:  brew install hudochenkov/sshpass/sshpass"
    echo ""
  fi

  check_ssh
  print_divider

  step_start "Creating folder on server: $SERVER_PATH"
  remote "mkdir -p $SERVER_PATH && echo 'Folder ready: '$SERVER_PATH"
  step_ok "Remote folder ready"

  step_start "Checking remote disk space..."
  echo ""
  remote "df -h $SERVER_PATH 2>/dev/null | awk 'NR==1{print \"  \"\$0} NR==2{print \"  \"\$0}'"
  echo ""
  step_ok "Disk space checked"

  print_divider
  echo -e "${BOLD}[$(ts)] Transferring files to server...${NC}"
  echo ""

  step_start "Uploading Docker image tar..."
  push_file_progress "$TAR_FILE" "$SERVER_PATH/"
  step_ok "Docker image tar uploaded"

  step_start "Uploading docker-compose.yml..."
  push_file_progress "docker-compose.yml" "$SERVER_PATH/"
  step_ok "docker-compose.yml uploaded"

  step_start "Uploading .env..."
  push_file_progress ".env" "$SERVER_PATH/"
  step_ok ".env uploaded"

  step_start "Verifying transferred files on server..."
  echo ""
  remote "ls -lh $SERVER_PATH/ | awk '{print \"  \"\$0}'"
  echo ""
  step_ok "Files verified on server"
  print_divider

  echo -e "${BOLD}[$(ts)] Loading image and restarting on server...${NC}"
  echo ""

  remote bash << REMOTE
    set -e
    echo "  [REMOTE] Working directory: $SERVER_PATH"
    cd $SERVER_PATH

    echo ""
    echo "  ── Step R1: Stopping existing containers ──────────────"
    docker compose down --remove-orphans 2>&1 | sed 's/^/  /' || true

    echo ""
    echo "  ── Step R2: Force removing known containers ───────────"
    docker rm -f ${APP_NAME}_app redis_container 2>&1 | sed 's/^/  /' || true

    echo ""
    echo "  ── Step R3: Checking for port conflicts on $APP_PORT ──"
    CONFLICTING=\$(docker ps -q --filter "publish=$APP_PORT")
    if [ -n "\$CONFLICTING" ]; then
      echo "  Removing conflicting container(s): \$CONFLICTING"
      docker rm -f \$CONFLICTING 2>&1 | sed 's/^/  /'
    else
      echo "  No port conflicts found on $APP_PORT"
    fi

    echo ""
    echo "  ── Step R4: Loading Docker image from tar ─────────────"
    LOAD_START=\$SECONDS
    docker load -i $TAR_FILE 2>&1 | sed 's/^/  /'
    echo "  Load time: \$((SECONDS - LOAD_START))s"

    echo ""
    echo "  ── Step R5: Listing available images ──────────────────"
    docker images | grep -E "REPOSITORY|$IMAGE_NAME" | sed 's/^/  /'

    echo ""
    echo "  ── Step R6: Starting services via docker compose ──────"
    docker compose up -d 2>&1 | sed 's/^/  /'

    echo ""
    echo "  ── Step R7: Waiting for containers to settle (5s) ──────"
    sleep 5

    echo ""
    echo "  ── Step R8: Container status ───────────────────────────"
    docker compose ps 2>&1 | sed 's/^/  /'

    echo ""
    echo "  ── Step R9: Container resource usage ───────────────────"
    docker stats --no-stream 2>&1 | sed 's/^/  /' || true

    echo ""
    echo "  ── Step R10: Last 20 lines of app logs ─────────────────"
    docker compose logs --tail=20 app 2>&1 | sed 's/^/  /' || true

    echo ""
    echo "  ── Step R11: Cleaning old image layers ─────────────────"
    docker image prune -f 2>&1 | sed 's/^/  /'

    echo ""
    echo "  ── Step R12: Final disk usage ──────────────────────────"
    df -h $SERVER_PATH | sed 's/^/  /'
    echo ""
    echo "  [REMOTE] All steps complete."
REMOTE

  print_summary
  echo -e "  ${GREEN}✅ Deployment complete!${NC}"
  echo -e "  ${DIM}   Total deploy time : $((SECONDS - PUSH_TOTAL_START))s${NC}"
  echo ""
  echo -e "  ${BOLD}App URL :${NC} http://$SERVER_IP:$APP_PORT"
  echo ""
}

do_restart() {
  print_header "Restart on $SERVER_IP"
  check_ssh
  step_start "Restarting services on server..."
  echo ""

  remote bash << REMOTE
    set -e
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
      echo "  Removing conflicting: \$CONFLICTING"
      docker rm -f \$CONFLICTING 2>&1 | sed 's/^/  /'
    else
      echo "  No port conflicts"
    fi

    echo ""
    echo "  ── Starting services ───────────────────────────────────"
    docker compose up -d 2>&1 | sed 's/^/  /'

    echo ""
    sleep 5
    echo "  ── Container status ────────────────────────────────────"
    docker compose ps 2>&1 | sed 's/^/  /'

    echo ""
    echo "  ── Last 20 log lines ───────────────────────────────────"
    docker compose logs --tail=20 app 2>&1 | sed 's/^/  /' || true
REMOTE

  step_ok "Restart complete"
  echo -e "  ${BOLD}App URL :${NC} http://$SERVER_IP:$APP_PORT"
  echo ""
}

do_stop() {
  print_header "Stop on $SERVER_IP"
  check_ssh
  step_start "Stopping all containers on server..."
  remote bash << REMOTE
    cd $SERVER_PATH
    docker compose down --remove-orphans 2>&1 | sed 's/^/  /'
    echo ""
    echo "  ── Remaining containers ────────────────────────────────"
    docker ps 2>&1 | sed 's/^/  /'
REMOTE
  step_ok "All containers stopped"
}

do_logs() {
  print_header "Logs from $SERVER_IP"
  check_ssh
  echo -e "${DIM}  Tailing logs... Ctrl+C to exit${NC}"
  echo ""
  remote "cd $SERVER_PATH && docker compose logs -f app"
}

do_local() {
  print_header "Local Test"
  step_start "Building image locally..."
  docker build -t "$IMAGE_NAME:latest" --build-arg DATABASE_URL="$DATABASE_URL" .
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
  *)
    echo "Usage: ./deploy.sh [build|push|restart|stop|logs|local]"
    exit 1
    ;;
esac
