#!/bin/sh
# DevOps Stage 1 — Automated Deployment Script (POSIX /bin/sh)
# Idempotent, logs everything, supports cleanup.

set -eu

# -------- Constants --------
DATE_STAMP="$(date +%Y%m%d_%H%M%S)"
LOGFILE="deploy_${DATE_STAMP}.log"
DEFAULT_BRANCH="main"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10"
REQUIRED_LOCAL_CMDS="git ssh rsync curl"

# -------- Helpers --------
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOGFILE"; }
fail() { log "ERROR: $*"; exit 1; }

confirm_cmds() {
  for c in $REQUIRED_LOCAL_CMDS; do
    command -v "$c" >/dev/null 2>&1 || fail "Missing required local tool: $c"
  done
}

sanitize() {
  # Hide PAT in echoed/logged URLs
  echo "$1" | sed 's#https\?://[^@]\+@#https://***@#g'
}

ask() {
  # $1=prompt  $2=default (optional)
  if [ "${2-}" ]; then
    printf "%s [%s]: " "$1" "$2"
  else
    printf "%s: " "$1"
  fi
  IFS= read -r v || true
  if [ -z "${v}" ] && [ "${2-}" ]; then
    v="$2"
  fi
  printf '%s' "$v"
}

ask_secret() {
  # Prompt without echo
  printf "%s: " "$1"
  stty -echo 2>/dev/null || true
  IFS= read -r s || true
  stty echo 2>/dev/null || true
  printf "\n" 1>&2
  printf '%s' "$s"
}

ensure_ssh() {
  # quick connectivity check
  ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_IP" "echo connected" >/dev/null 2>&1 || fail "SSH failed. Check IP/user/key perms."
}

remote() {
  # Run remote command string
  ssh $SSH_OPTS -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" "$1"
}

remote_sh() {
  # Run a heredoc on remote via sh
  ssh $SSH_OPTS -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" 'sh -s' <<'EOF'
set -eu
# No-op placeholder; replaced at runtime
EOF
}

usage() {
  cat <<USAGE
Usage: $0 [--cleanup]

No args -> guided deployment with prompts.
--cleanup -> remove remote app, containers, nginx config, and files.
USAGE
  exit 0
}

# -------- Parse flags --------
CLEANUP="no"
[ "${1-}" = "--help" ] && usage
[ "${1-}" = "-h" ] && usage
[ "${1-}" = "--cleanup" ] && CLEANUP="yes"

# -------- Preconditions --------
confirm_cmds
touch "$LOGFILE"
log "Logging to $LOGFILE"

# -------- Collect inputs --------
REPO_URL="$(ask 'Git repository (HTTPS)' '')"
[ -z "$REPO_URL" ] && fail "Repo URL required (HTTPS)."
case "$REPO_URL" in
  https://github.com/*) : ;;
  https://*) log "Non-GitHub HTTPS URL provided — proceeding."; ;
  *) fail "Provide an HTTPS Git URL."
esac

PAT="$(ask_secret 'Git Personal Access Token (PAT)')"
[ -z "$PAT" ] && fail "PAT is required."

BRANCH="$(ask 'Branch name' "$DEFAULT_BRANCH")"
REMOTE_USER="$(ask 'Remote SSH username' '')"
[ -z "$REMOTE_USER" ] && fail "SSH username required."
REMOTE_IP="$(ask 'Remote server IP/DNS' '')"
[ -z "$REMOTE_IP" ] && fail "Server IP/DNS required."
SSH_KEY="$(ask 'SSH private key path' "$HOME/.ssh/id_rsa")"
[ -f "$SSH_KEY" ] || fail "SSH key not found at $SSH_KEY."
APP_PORT="$(ask 'Application internal container port (e.g., 8000, 3000)' '')"
[ -n "$APP_PORT" ] || fail "Application port required."

# Derive repo name
REPO_NAME="$(basename "$REPO_URL" .git)"
[ -z "$REPO_NAME" ] && fail "Could not determine repo name."
log "Repo: $REPO_NAME"
log "Branch: $BRANCH"
log "Remote: $REMOTE_USER@${REMOTE_IP}"
log "Container internal port: $APP_PORT"

# -------- Clone/Pull locally (auth via PAT) --------
AUTH_URL="$(echo "$REPO_URL" | sed "s#https://#https://${PAT}@#")"
log "Cloning or pulling: $(sanitize "$AUTH_URL")"
if [ -d "$REPO_NAME/.git" ]; then
  ( cd "$REPO_NAME" && git fetch --all && git checkout "$BRANCH" && git pull --ff-only origin "$BRANCH" ) \
    || fail "Git pull failed."
else
  git clone --branch "$BRANCH" "$AUTH_URL" "$REPO_NAME" || fail "Git clone failed."
fi

cd "$REPO_NAME"
[ -f "docker-compose.yml" ] || [ -f "Docker-compose.yml" ] || [ -f "docker-compose.yaml" ] || [ -f "Dockerfile" ] || fail "No Dockerfile or docker-compose.yml found."
log "Project directory ready: $(pwd)"

# -------- SSH connectivity check --------
log "Checking SSH connectivity..."
ensure_ssh
log "SSH OK."

# -------- Cleanup path --------
if [ "$CLEANUP" = "yes" ]; then
  log "Starting remote cleanup..."
  ssh $SSH_OPTS -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" "set -eu
    APP_DIR=/opt/apps/${REPO_NAME}
    SITE=/etc/nginx/sites-available/${REPO_NAME}.conf
    [ -x /usr/bin/docker ] || [ -x /usr/bin/dockerd ] || true
    if command -v docker >/dev/null 2>&1; then
      if docker ps -a --format '{{.Names}}' | grep -q '^${REPO_NAME}_app$'; then docker rm -f ${REPO_NAME}_app || true; fi
      if docker compose version >/dev/null 2>&1 && [ -f \"\$APP_DIR/docker-compose.yml\" ]; then
        (cd \"\$APP_DIR\" && docker compose down --remove-orphans || true)
      elif command -v docker-compose >/dev/null 2>&1 && [ -f \"\$APP_DIR/docker-compose.yml\" ]; then
        (cd \"\$APP_DIR\" && docker-compose down --remove-orphans || true)
      fi
      docker network rm ${REPO_NAME}_net 2>/dev/null || true
      docker image rm ${REPO_NAME}:latest 2>/dev/null || true
    fi
    rm -rf \"\$APP_DIR\"
    rm -f \"\$SITE\"
    rm -f /etc/nginx/sites-enabled/${REPO_NAME}.conf
    [ -f /etc/nginx/sites-enabled/default ] || true
    nginx -t && systemctl reload nginx || true
  " || fail "Cleanup failed."
  log "Cleanup complete."
  exit 0
fi

# -------- Prepare remote host --------
log "Preparing remote host (Docker, Compose, Nginx)..."
ssh $SSH_OPTS -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" "set -eu
  export DEBIAN_FRONTEND=noninteractive
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y
    sudo apt-get install -y ca-certificates curl gnupg lsb-release rsync
    # Docker (Debian/Ubuntu convenience)
    if ! command -v docker >/dev/null 2>&1; then
      sudo apt-get install -y docker.io
    fi
    # Compose v2 plugin
    if ! docker compose version >/dev/null 2>&1; then
      sudo apt-get install -y docker-compose-plugin || true
    fi
    # Fallback legacy compose
    if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
      sudo apt-get install -y docker-compose || true
    fi
    # Nginx
    if ! command -v nginx >/dev/null 2>&1; then
      sudo apt-get install -y nginx
    fi
    # Enable services
    sudo systemctl enable --now docker || true
    sudo systemctl enable --now nginx || true
    sudo usermod -aG docker $USER || true
  else
    echo 'Non-Debian family detected; please install docker, compose, nginx manually.' >&2
    exit 2
  fi
  docker --version || true
  if docker compose version >/dev/null 2>&1; then docker compose version; elif command -v docker-compose >/dev/null 2>&1; then docker-compose version; fi
  nginx -v
" || fail "Remote preparation failed."
log "Remote host ready."

# -------- Transfer project --------
REMOTE_APP_DIR="/opt/apps/${REPO_NAME}"
log "Syncing project to ${REMOTE_USER}@${REMOTE_IP}:${REMOTE_APP_DIR}"
ssh $SSH_OPTS -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" "sudo mkdir -p '$REMOTE_APP_DIR' && sudo chown -R $REMOTE_USER:$REMOTE_USER '$REMOTE_APP_DIR'"
# exclude .git and local logs
rsync -az --delete -e "ssh $SSH_OPTS -i $SSH_KEY" \
  --exclude '.git' --exclude '*.log' ./ "$REMOTE_USER@$REMOTE_IP:$REMOTE_APP_DIR/" \
  || fail "rsync failed"

# -------- Deploy on remote (Compose or Dockerfile) --------
log "Deploying containers on remote..."
ssh $SSH_OPTS -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" "set -eu
  APP_DIR='$REMOTE_APP_DIR'
  APP_PORT='$APP_PORT'
  REPO_NAME='$REPO_NAME'
  cd \"\$APP_DIR\"

  # Prefer compose if file exists
  if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ] || [ -f Docker-compose.yml ]; then
    if docker compose version >/dev/null 2>&1; then
      docker compose pull || true
      docker compose up -d --build --remove-orphans
    elif command -v docker-compose >/dev/null 2>&1; then
      docker-compose pull || true
      docker-compose up -d --build --remove-orphans
    else
      echo 'No docker compose available' >&2; exit 3
    fi
  else
    # Single Dockerfile path
    CONTAINER_NAME=\"\${REPO_NAME}_app\"
    IMAGE_TAG=\"\${REPO_NAME}:latest\"
    docker rm -f \"\$CONTAINER_NAME\" 2>/dev/null || true
    docker build -t \"\$IMAGE_TAG\" .
    # Map to loopback; Nginx will proxy from :80
    docker run -d --restart=always --name \"\$CONTAINER_NAME\" -p 127.0.0.1:\$APP_PORT:\$APP_PORT \"\$IMAGE_TAG\"
  fi

  # Basic container check
  sleep 3
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
" || fail "Remote container deployment failed."

# -------- Nginx reverse proxy --------
log "Configuring Nginx reverse proxy..."
NGINX_SITE="/etc/nginx/sites-available/${REPO_NAME}.conf"
ssh $SSH_OPTS -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" "set -eu
  APP_PORT='$APP_PORT'
  SITE='$NGINX_SITE'
  sudo bash -c 'cat > '"$NGINX_SITE" <<'NGX'
server {
    listen 80;
    server_name _;

    # Optional: place Certbot here later
    # include /etc/letsencrypt/options-ssl-nginx.conf;

    location / {
        proxy_pass http://127.0.0.1:APPPORT;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
    }
}
NGX
"
# Substitute APPPORT placeholder
ssh $SSH_OPTS -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" "sudo sed -i 's/APPPORT/${APP_PORT}/g' '$NGINX_SITE'"

# Enable site and reload
ssh $SSH_OPTS -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" "set -eu
  sudo rm -f /etc/nginx/sites-enabled/default || true
  sudo ln -sf '$NGINX_SITE' '/etc/nginx/sites-enabled/${REPO_NAME}.conf'
  sudo nginx -t
  sudo systemctl reload nginx
" || fail "Nginx configuration failed."
log "Nginx proxy ready."

# -------- Validation --------
log "Validating services..."
ssh $SSH_OPTS -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" "set -eu
  systemctl is-active --quiet docker || (echo 'Docker inactive' >&2; exit 4)
  systemctl is-active --quiet nginx || (echo 'Nginx inactive' >&2; exit 5)
  # local health check via loopback
  curl -fsS -o /dev/null -m 8 http://127.0.0.1/ || (echo 'Local Nginx proxy check failed' >&2; exit 6)
"
log "Remote checks passed."

log "External check from here (may fail if firewalls block 80): http://$REMOTE_IP/"
if curl -fsS -I -m 8 "http://$REMOTE_IP/" >/dev/null 2>&1; then
  log "✅ External HTTP reachable."
else
  log "⚠ External HTTP not reachable from here. Verify security groups / firewalls / ISP."
fi

log "Deployment complete. Re-run this script any time; it's idempotent."
log "To remove everything later: $0 --cleanup"

