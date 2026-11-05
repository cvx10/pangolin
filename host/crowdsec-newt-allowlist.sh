#!/usr/bin/env bash
# Keep the CrowdSec allowlist "newt-sites" equal to the public IP(s) the newt
# sites connect from, i.e. the home connection, whose IP is dynamic.
# Run every 5 min by crowdsec-newt-allowlist.timer (installed by host/install.sh).
#
# Why: newt retries get-token every 3 s. Once the home IP is banned for any
# reason, each retry gets a 403 from the bouncer, which feeds
# LePresidente/http-generic-403-bf and renews the ban for as long as newt keeps
# trying: both tunnels down, every public site down. 2026-11-05: a Home
# Assistant panel answered ~90 403s in a minute right after a Proxmox
# maintenance (crowdsecurity/http-probing), the newt pods restarted during the
# ban, and the loop held until the decisions were deleted by hand.
#
# Source of truth: Pangolin's own sites.endpoint (+ lastHolePunch), written when
# gerbil relays newt's hole punch. That UDP path does not go through Traefik,
# so it keeps working while the IP is banned, and Pangolin only accepts it with
# the newt's session token. Read-only access to the DB. Nothing is published in
# DNS and nothing is pushed from home.
#
# When no newt site has punched recently (tunnels down), the allowlist is left
# untouched: that is exactly when it must keep holding the last known IP.
set -Eeuo pipefail

REPO_DIR=${REPO_DIR:-$(dirname "$(dirname "$(readlink -f "$0")")")}
DB="$REPO_DIR/config/db/db.sqlite"
LIST=newt-sites
MAX_AGE=600 # seconds since a site's last hole punch (newt punches every few s)

cscli() { docker exec crowdsec cscli "$@"; }
log() { echo "$*"; }

# Fresh newt endpoints → set of public IPs. Any schema change or garbage value
# raises, so the unit fails instead of silently emptying the list.
fresh=$(python3 - "$DB" "$MAX_AGE" <<'PY'
import ipaddress, sqlite3, sys, time
db, max_age = sys.argv[1], int(sys.argv[2])
c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
ips = set()
rows = c.execute("select endpoint, lastHolePunch from sites where type = 'newt'")
for endpoint, last in rows:
    if not endpoint or not last or time.time() - int(last) > max_age:
        continue
    ip = ipaddress.ip_address(endpoint.rsplit(":", 1)[0].strip("[]"))
    if ip.is_global:
        ips.add(str(ip))
print("\n".join(sorted(ips)))
PY
)

if [ -z "$fresh" ]; then
  log "no newt site punched in the last ${MAX_AGE}s: allowlist left as is"
  exit 0
fi

current=$(cscli allowlists inspect "$LIST" -o json | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("\n".join(sorted(i["value"] for i in (d.get("items") or []))))
')

for ip in $fresh; do
  if ! grep -qxF "$ip" <<<"$current"; then
    cscli allowlists add "$LIST" "$ip" -d "newt site endpoint, seen $(date -u +%FT%TZ)"
    log "added $ip to $LIST"
  fi
  # An allowlist stops new decisions; it does not lift one already active.
  # cscli 1.8 prints [] when there is none (older versions: null).
  case "$(cscli decisions list -i "$ip" -o json | tr -d '[:space:]')" in
    '[]' | null | '') ;;
    *)
      cscli decisions delete --ip "$ip"
      log "deleted active decisions on $ip"
      ;;
  esac
done

for ip in $current; do
  if ! grep -qxF "$ip" <<<"$fresh"; then
    cscli allowlists remove "$LIST" "$ip"
    log "removed stale $ip from $LIST"
  fi
done
