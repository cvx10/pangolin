#!/usr/bin/env bash
# Install the host-side pieces of this stack. Idempotent.
#
#   /etc/logrotate.d/pangolin-traefik          rotate the Traefik access log
#   crowdsec-newt-allowlist.{service,timer}    allowlist the newt sites' IP
#
# Run by .github/workflows/deploy.yml after deploy.sh succeeded. By hand on the
# VPS: bash host/install.sh. Files carry @REPO_DIR@, replaced by this checkout's
# path, so nothing here assumes /root/pangolin.
set -Eeuo pipefail
cd "$(dirname "$(dirname "$(readlink -f "$0")")")"
REPO_DIR=$(pwd)

log() { echo "$(date '+%H:%M:%S') $*"; }

# install_rendered <src> <dest>: render @REPO_DIR@, write only on change.
# Returns 0 when <dest> changed, 1 when it was already up to date.
install_rendered() {
  local tmp
  tmp=$(mktemp)
  sed "s|@REPO_DIR@|$REPO_DIR|g" "$1" >"$tmp"
  if cmp -s "$tmp" "$2"; then
    rm -f "$tmp"
    return 1
  fi
  install -m 0644 "$tmp" "$2"
  rm -f "$tmp"
  log "installed $2"
}

# --- logrotate --------------------------------------------------------------
install_rendered host/logrotate/pangolin-traefik /etc/logrotate.d/pangolin-traefik || true
# Dry run: fails the deploy on a broken config instead of at midnight.
logrotate --debug /etc/logrotate.d/pangolin-traefik >/dev/null 2>&1

# --- CrowdSec allowlist for the newt sites ----------------------------------
if ! docker exec crowdsec cscli allowlists inspect newt-sites >/dev/null 2>&1; then
  docker exec crowdsec cscli allowlists create newt-sites \
    -d "Public IP(s) of the newt sites (home). Managed by host/crowdsec-newt-allowlist.sh"
  log "created CrowdSec allowlist newt-sites"
fi

units_changed=0
for unit in crowdsec-newt-allowlist.service crowdsec-newt-allowlist.timer; do
  if install_rendered "host/systemd/$unit" "/etc/systemd/system/$unit"; then
    units_changed=1
  fi
done
if [ "$units_changed" = 1 ]; then
  systemctl daemon-reload
fi
systemctl enable --now crowdsec-newt-allowlist.timer
# First sync now: a broken script fails the deploy, not silently every 5 min.
systemctl start crowdsec-newt-allowlist.service
log "allowlist newt-sites: $(docker exec crowdsec cscli allowlists inspect newt-sites -o json |
  python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("items") or []))') value(s)"
log "✅ host install complete"
