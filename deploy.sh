#!/bin/bash
# DevOps Stage 1 - Automated Deployment Script (bash, macOS-friendly)
set -euo pipefail

DATE_STAMP="$(date +%Y%m%d_%H%M%S)"
LOGFILE="deploy_${DATE_STAMP}.log"
DEFAULT_BRANCH="main"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10"
REQUIRED_LOCAL_CMDS=("git" "ssh" "rsync" "curl")

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOGFILE"; }
fail() { log "ERROR: $*"; exit 1; }
confirm_cmds() { for c in "${REQUIRED_LOCAL_CMDS[@]}"; do command -v "$c" >/dev/null 2>&1 || fail "Missing tool: $c"; done; }
sanitize() { sed 's#https\{0,1\}://[^@]\+@#https://***@#g'; }

ask() {
  local prompt="${1}" def="${2-}" v
  if [[ -n "${def}" ]]; then printf "%s [%s]: " "$prompt" "$def"; else printf "%s: " "$prompt"; fi
  IFS= read -r v || true
  [[ -z "$v" && -n "${def}" ]] && v="$def"
  printf "%s" "$v"
}
ask_secret() {
  local prompt="${1}" s
  printf "%s: " "$prompt" 1>&2
  stty -echo 2>/dev/null || true; IFS= read -r s || true; stty echo 2>/dev/null || true; printf "\n" 1>&2
  printf "%s" "$s"
}
ensure_ssh() { ssh $SSH_OPTS -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" "echo connected" >/dev/null 2>&1 || fail "SSH failed"; }
remote() { ssh $SSH_OPTS -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" "$1"; }

usage(){ cat <<USAGE
Usage: $0 [--cleanup]
No args   -> guided deployment with prompts.
--cleanup -> remove remote app, containers, nginx site, and files.
USAGE
; }

CLEANUP="no"
[[ "${1-}" == "--help" || "${1-}" == "-h" ]] && usage
[[ "${1-}" == "--cleanup" ]] && CLEANUP="yes"

touch "$LOGFILE"; log "Logging to $LOGFILE"; confirm_cmds

# -------- Collect inputs --------
REPO_URL="$(ask 'Git repository (HTTPS)' '')"
REPO_URL="$(printf '%s' "$REPO_URL" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
[[ -z "$REPO_URL" ]] && fail "Repo URL required (HTTPS)."

case "$REPO_URL" in
  https://*.git) : ;;
  https://*) fail "Use the HTTPS .git URL (copy from GitHub 'Code' button).";;
  *) fail "Provide an HTTPS Git URL.";;
esac

PAT="$(ask_secret 'Git Personal Access Token (PAT)')"
[[ -z "$PAT" ]] && fail "PAT is required."
BRANCH="$(ask 'Branch name' "$DEFAULT_BRANCH")"

REMOTE_USER="$(ask 'Remote SSH username' '')"; [[ -z "$REMOTE_USER" ]] && fail "SSH username required."
REMOTE_IP="$(ask 'Remote server IP/DNS' '')"; [[ -z "$REMOTE_IP" ]] && fail "Server IP/DNS required."
SSH_KEY="$(ask 'SSH private key path' "$HOME/.ssh/hng-key.pem")"; [[ -f "$SSH_KEY" ]] || fail "SSH key not found at $SSH_KEY."
APP_PORT="$(ask 'Application internal container port (e.g., 8000, 3000)' '')"; [[ -n "$APP_PORT" ]] || fail "Application port required."

REPO_NAME="$(basename "$REPO_URL" .git)"; [[ -z "$REPO_NAME" ]] && fail "Could not determine repo name."
log "Repo: $REPO_NAME"; log "Branch: $BRANCH"; log "Remote: $REMOTE_USER@$REMOTE_IP"; log "Port: $APP_PORT"

AUTH_URL="${REPO_URL/https:\/\//https:\/\/${PAT}@}"
log "Cloning/pulling: $(printf '%s' "$AUTH_URL" | sanitize)"
if [[ -d "$REPO_NAME/.git" ]]; then
  ( cd "$REPO_NAME" && git fetch --all && git checkout "$BRANCH" && git pull --ff-only origin "$BRANCH" ) || fail "Git pull failed."
else
  git clone --branch "$BRANCH" "$AUTH_URL" "$REPO_NAME" || fail "Git clone failed."
fi

cd "$REPO_NAME"
[[ -f docker-compose.yml || -f docker-compose.yaml || -f Docker-compose.yml || -f Dockerfile ]] || fail "No Dockerfile or docker-compose.yml found."
log "Project OK: $(pwd)"

log "Checking SSH connectivity..."; ensure_ssh; log "SSH OK."

if [[ "$CLEANUP" == "yes" ]]; then
  log "Starting remote cleanup..."
  remote "set -euo pipefail
APP_DIR=/opt/apps/${REPO_NAME}
SITE=/etc/nginx/sites-available/${REPO_NAME}.conf
if command -v docker >/dev/null 2>&1; then
  if [ -f \"\$APP_DIR/docker-compose.yml\" ] || [ -f \"\$APP_DIR/docker-compose.yaml\" ]; then
    if docker compose version >/dev/null 2>&1; then (cd \"\$APP_DIR\" && docker compose down --remove-orphans || true)
    elif command -v docker-compose >/dev/null 2>&1; then (cd \"\$APP_DIR\" && docker-compose down --remove-orphans || true); fi
  fi
  if docker ps -a --format '{{.Names}}' | grep -q '^${REPO_NAME}_app$'; then docker rm -f ${REPO_NAME}_app || true; fi
  docker network rm ${REPO_NAME}_net 2>/dev/null || true
  docker image rm ${REPO_NAME}:latest 2>/dev/null || true
fi
rm -rf \"\$APP_DIR\"
rm -f \"\$SITE\" /etc/nginx/sites-enabled/${REPO_NAME}.conf
nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
"; log "Cleanup complete."; exit 0; fi

log "Preparing remote host (Docker, Compose, Nginx)..."
remote "set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release rsync
command -v docker >/dev/null 2>&1 || sudo apt-get install -y docker.io
docker compose version >/dev/null 2>&1 || sudo apt-get install -y docker-compose-plugin || true
if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then sudo apt-get install -y docker-compose || true; fi
command -v nginx >/dev/null 2>&1 || sudo apt-get install -y nginx
sudo systemctl enable --now docker || true
sudo systemctl enable --now nginx || true
sudo usermod -aG docker \$USER || true
docker --version || true
if docker compose version >/dev/null 2>&1; then docker compose version; elif command -v docker-compose >/dev/null 2>&1; then docker-compose version; fi
nginx -v
"; log "Remote host ready."

REMOTE_APP_DIR="/opt/apps/${REPO_NAME}"
log "Syncing project to ${REMOTE_USER}@${REMOTE_IP}:${REMOTE_APP_DIR}"
remote "sudo mkdir -p '$REMOTE_APP_DIR' && sudo chown -R $REMOTE_USER:$REMOTE_USER '$REMOTE_APP_DIR'"
rsync -az --delete -e "ssh $SSH_OPTS -i $SSH_KEY" --exclude '.git' --exclude '*.log' ./ "$REMOTE_USER@$REMOTE_IP:$REMOTE_APP_DIR/" || fail "rsync failed"

log "Deploying containers on remote..."
remote "set -euo pipefail
APP_DIR='$REMOTE_APP_DIR'; APP_PORT='$APP_PORT'; REPO_NAME='$REPO_NAME'
cd \"\$APP_DIR\"
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ] || [ -f Docker-compose.yml ]; then
  if docker compose version >/dev/null 2>&1; then docker compose pull || true; docker compose up -d --build --remove-orphans
  elif command -v docker-compose >/dev/null 2>&1; then docker-compose pull || true; docker-compose up -d --build --remove-orphans
  else echo 'No docker compose available' >&2; exit 3; fi
else
  CONTAINER_NAME=\"\${REPO_NAME}_app\"; IMAGE_TAG=\"\${REPO_NAME}:latest\"
  docker rm -f \"\$CONTAINER_NAME\" 2>/dev/null || true
  docker build -t \"\$IMAGE_TAG\" .
  docker run -d --restart=always --name \"\$CONTAINER_NAME\" -p 127.0.0.1:\$APP_PORT:\$APP_PORT \"\$IMAGE_TAG\"
fi
sleep 3
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
" || fail "Remote container deployment failed."

log "Configuring Nginx reverse proxy..."
NGINX_SITE="/etc/nginx/sites-available/${REPO_NAME}.conf"
remote "set -euo pipefail
APP_PORT='$APP_PORT'; SITE='$NGINX_SITE'
sudo bash -c 'cat > '\"$NGINX_SITE\" <<NGX
server {
  listen 80;
  server_name _;
  location / {
    proxy_pass http://127.0.0.1:APPPORT;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
NGX
sudo sed -i.bak \"s/APPPORT/${APP_PORT}/g\" \"$NGINX_SITE\"
sudo rm -f /etc/nginx/sites-enabled/default || true
sudo ln -sf \"$NGINX_SITE\" \"/etc/nginx/sites-enabled/${REPO_NAME}.conf\"
sudo nginx -t
sudo systemctl reload nginx
" || fail "Nginx configuration failed."
log "Nginx proxy ready."

log "Validating services..."
remote "set -euo pipefail
systemctl is-active --quiet docker || (echo 'Docker inactive' >&2; exit 4)
systemctl is-active --quiet nginx || (echo 'Nginx inactive' >&2; exit 5)
curl -fsS -o /dev/null -m 8 http://127.0.0.1/ || (echo 'Local Nginx proxy check failed' >&2; exit 6)
"
log "Remote checks passed."

log "External check from here: http://$REMOTE_IP/"
if curl -fsS -I -m 8 "http://$REMOTE_IP/" >/dev/null 2>&1; then log "OK: External HTTP reachable."; else log "WARN: External HTTP not reachable from here."; fi
log "Deployment complete. Re-run anytime; idempotent."
log "To remove everything later: $0 --cleanup"
