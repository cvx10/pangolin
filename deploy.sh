#!/usr/bin/env bash
# Deploy the Pangolin stack on the VPS, with a real rollback.
#
# Called by .github/workflows/deploy.yml AFTER it has absorbed the config drift
# and pulled main. Usage: bash deploy.sh <previous-commit>
#
#   snapshot DB → render config → pull → up -d → health check
#   any failure → back to <previous-commit> + DB restored → up -d → exit 1
#
# ⚠️ Restoring the DB is the ONLY real rollback of a Pangolin upgrade: it runs
#    its SQLite migrations at start and they are irreversible. Never remove the
#    snapshot step. Same pattern as cvx10/uptime-kuma deploy.sh.
#
# ⚠️ A rollback resets the checkout to <previous-commit> but origin/main still
#    holds the bad commit, so the NEXT deploy pulls it again and fails the same
#    way. Fix it in git (revert or pin), not on the VPS.
# -E: the ERR trap must also fire for failures inside functions.
set -Eeuo pipefail

cd "$(dirname "$(readlink -f "$0")")"

PREV="${1:?usage: deploy.sh <previous-commit>}"
DB=config/db/db.sqlite
# Outside this public checkout, never in it: the DB holds every site secret.
BACKUP_DIR=/root/backups/pangolin
DB_PREV="$BACKUP_DIR/db.sqlite.prev"
PUBLIC_HOST=pangolin.lupica.be
HEALTH_TRIES=30 # × 5 s. Pangolin's own healthcheck allows 15 × 10 s at start.
restart_pangolin=0

log() { echo "$(date '+%H:%M:%S') $*"; }

# Hot, consistent copy without stopping Pangolin. sqlite3 is not on the host;
# python3 is. A plain cp could capture a half-written WAL.
snapshot_db() {
  install -d -m 0700 "$BACKUP_DIR"
  # Never let a previous deploy's snapshot be restored by this one.
  rm -f "$DB_PREV"
  if [ ! -s "$DB" ]; then
    log "📸 no $DB yet (first deploy) — nothing to snapshot"
    return 0
  fi
  python3 - "$DB" "$DB_PREV" <<'PY'
import sqlite3, sys
src, dst = sys.argv[1], sys.argv[2]
s = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
d = sqlite3.connect(dst)
with d:
    s.backup(d)
d.close(); s.close()
PY
  chmod 600 "$DB_PREV"
  log "📸 DB snapshot → $DB_PREV"
}

render_config() {
  # Exit 10 = config.yml changed: pangolin reads it at start only.
  local rc=0
  python3 render-config.py || rc=$?
  case $rc in
    0) restart_pangolin=0 ;;
    10) restart_pangolin=1 ;;
    *) return 1 ;;
  esac
}

# Every service must run, pangolin must pass its own healthcheck, and the
# public path (gerbil ports → traefik → pangolin) must answer. The old check
# grepped for ONE "healthy" anywhere in `docker compose ps`, so a dead traefik
# or gerbil passed as long as pangolin was up.
healthy() {
  local svc state health
  for svc in pangolin gerbil traefik crowdsec; do
    state=$(docker compose ps --format '{{.State}}' "$svc" 2>/dev/null)
    [ "$state" = running ] || return 1
  done
  health=$(docker compose ps --format '{{.Health}}' pangolin 2>/dev/null)
  [ "$health" = healthy ] || return 1
  curl -fsS -o /dev/null --max-time 5 \
    --resolve "$PUBLIC_HOST:443:127.0.0.1" "https://$PUBLIC_HOST/api/v1/"
}

wait_healthy() {
  local i
  for i in $(seq 1 "$HEALTH_TRIES"); do
    if healthy; then
      log "   healthy after ${i} check(s)"
      return 0
    fi
    sleep 5
  done
  docker compose ps
  docker compose logs --tail=50 pangolin
  return 1
}

rollback() {
  trap - ERR
  log "❌ deploy failed — rolling back to ${PREV:0:7}"
  local pangolin_changed=0
  if git diff "$PREV" HEAD -- docker-compose.yml | grep -qE '^[-+].*fosrl/pangolin:'; then
    pangolin_changed=1
  fi
  git reset --hard -q "$PREV"
  render_config || true
  if [ "$pangolin_changed" = 1 ] && [ -s "$DB_PREV" ]; then
    # Only when the pangolin image moved: that is when migrations ran. For a
    # traefik or gerbil bump the live DB is fine, and restoring it would drop
    # whatever was written since the snapshot.
    docker compose stop pangolin || true
    cp -f "$DB_PREV" "$DB"
    # WAL/SHM belong to the NEW database; replaying them over the restored
    # copy would corrupt it.
    rm -f "$DB-wal" "$DB-shm"
    log "   DB restored"
  fi
  docker compose up -d --remove-orphans || true
  if wait_healthy; then
    log "   rollback healthy — still failing the job so it gets looked at"
  else
    log "   ⚠️ rollback NOT healthy — manual intervention needed"
  fi
  exit 1
}
trap rollback ERR

# --- 1. Snapshot ------------------------------------------------------------
snapshot_db

# --- 2. Config + images -----------------------------------------------------
log "🧩 rendering config/config.yml"
render_config

log "🐳 docker compose pull && up -d"
docker compose pull
docker compose up -d --remove-orphans
if [ "$restart_pangolin" = 1 ]; then
  log "🔁 config.yml changed, restarting pangolin"
  docker compose restart pangolin
fi

# --- 3. Health check --------------------------------------------------------
log "🏥 health check"
wait_healthy

trap - ERR
docker compose ps
log "🧹 pruning dangling images"
docker image prune -f >/dev/null
log "✅ deploy complete"
