# DevOps Stage-1 — Automated Docker Deployment (POSIX Shell)

Single-file **`deploy.sh`** automates:
- repo clone/pull (PAT), branch checkout
- remote prep (Docker, Compose, Nginx)
- file sync to `/opt/apps/<repo>`
- Docker deploy (Compose **or** Dockerfile)
- Nginx reverse proxy on port **80** → `127.0.0.1:<APP_PORT>`
- health checks, logging, idempotent re-runs
- `--cleanup` to remove everything

## Prereqs (Local)
- macOS/Linux with: `git`, `ssh`, `rsync`, `curl`
- A Git **HTTPS** repo URL and a GitHub **PAT** with `repo` scope
- SSH to a Debian/Ubuntu server (user must have `sudo`)

## Prereqs (Remote)
- Debian/Ubuntu (script installs Docker, docker compose plugin, Nginx)
- Port **80** open from the internet (security group / firewall)

## Usage
```bash
chmod +x deploy.sh
./deploy.sh
# Prompts:
# - Repo URL (HTTPS)
# - PAT (hidden)
# - Branch (default: main)
# - SSH user, server IP/DNS, SSH key path
# - App internal container port (e.g., 8000/3000)

