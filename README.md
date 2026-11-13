# Pangolin Stack

A self-hosted tunneling solution with built-in security features. This stack includes Pangolin, Gerbil (WireGuard-based tunneling), Traefik (reverse proxy with automatic HTTPS), and CrowdSec (security layer with virtual patching).

## 🏗️ Stack Components

| Component | Description | Port(s) |
|-----------|-------------|---------|
| **Pangolin** | Main application and dashboard | 3001 (internal) |
| **Gerbil** | WireGuard-based tunnel manager | 51820/udp, 21820/udp |
| **Traefik** | Reverse proxy with Let's Encrypt | 80, 443 |
| **CrowdSec** | Security layer with threat detection | - |

## 📋 Prerequisites

- Docker and Docker Compose
- A domain name with DNS pointing to your server
- Ports 80, 443, 51820/udp, and 21820/udp accessible

## 🚀 Quick Start

### 1. Clone and Configure

```bash
# Clone the repository
git clone https://github.com/cvx10/pangolin.git
cd pangolin

# Create your environment file (secrets live ONLY here, mode 0600)
cp .env.example .env && chmod 600 .env
nano .env

# Render config/config.yml from the versioned template
python3 render-config.py
```

### 2. Configure Your Settings

#### Environment Variables
Edit `.env` and set:
- `CROWDSEC_LAPI_KEY`: Get this by running `docker exec crowdsec cscli bouncers add traefik-bouncer`
- `LETS_ENCRYPT_EMAIL`: Your email address for SSL certificate notifications
- `PANGOLIN_DOMAIN`: The domain where Pangolin is hosted (e.g. `pangolin.example.com`)

#### Application Config (template)
`config/config.yml` is **generated** — never edit it on the server. The source is
`config/config.yml.tmpl` (versioned, no secrets); its `${VAR}` placeholders come from
`.env`:

- `PANGOLIN_SERVER_SECRET`: `openssl rand -base64 24` once — changing it later
  invalidates every Pangolin session
- `SMTP_USER`, `SMTP_PASS`, `SMTP_NO_REPLY`: SMTP for email verification (a Gmail app
  password contains spaces: keep it unquoted)

`render-config.py` reads `.env` without a shell (spaces survive), writes every value
as a quoted YAML string, fails on a missing variable, and only rewrites `config.yml`
when the parsed content changes — exit code **10** means "changed, restart
`pangolin`", which the deploy workflow does. `--check` compares without writing.

### 3. Download GeoIP Database

Download the MaxMind GeoLite2-Country database and place it at:
```
config/GeoLite2-Country.mmdb
```

### 4. Start the Stack

```bash
docker compose up -d
```

### 5. Configure GitHub Secrets (for CI/CD)

Go to your repository Settings → Secrets → Actions and add:

| Secret | Required | Description |
|--------|----------|-------------|
| `TS_OAUTH_CLIENT_ID` | yes | Tailscale OAuth client ID |
| `TS_OAUTH_SECRET` | yes | Tailscale OAuth secret |
| `TELEGRAM_BOT_TOKEN` | no | Bot token for deploy-failure alerts. Unset = alert skipped |
| `TELEGRAM_CHAT_ID` | no | Chat the failure alert is sent to |

SSH needs no key material: the runner joins the tailnet and authenticates with
its tailnet identity through Tailscale SSH.

### 6. Access the Dashboard

Navigate to `https://pangolin.your-domain.com` to access the Pangolin dashboard.

## 🔑 Integration API

Pangolin's Integration API (`flags.enable_integration_api: true` in
`config/config.yml`) lets resources, identity providers and blueprints be managed
with an API key instead of the dashboard.

- **Bound to `127.0.0.1:3003` only.** No Traefik router, no public hostname, no
  tailnet bind (a failed bind at boot would keep `pangolin` down, and with it every
  public site). Reach it from a workstation with an SSH tunnel:

  ```bash
  ssh -N -L 3003:127.0.0.1:3003 vps
  curl -H "Authorization: Bearer $(cat ~/.config/pangolin-api-key)" http://127.0.0.1:3003/v1/
  ```

- Swagger UI: `http://127.0.0.1:3003/v1/docs` through the same tunnel.
- API keys are created in the dashboard (*Server Admin → API Keys*). A **root** key is
  needed for server-level objects such as identity providers. Never commit one —
  this repository is public.
- The flag lives in `config/config.yml.tmpl` (`flags.enable_integration_api`); the
  deploy renders it into `config.yml` and restarts `pangolin` when it changes.
- Resources, their auth and the DNS records are managed as code in the **private**
  repository `cvx10/edge-iac` (Pangolin blueprint + Terraform), applied through this
  API. Dashboard edits to those resources are overwritten by its next deploy.

## 🔄 CI/CD

This repository includes automated deployment via GitHub Actions:

- **Dependabot**: Checks for Docker image updates weekly (Sundays 2:00 AM)
- **Auto-merge** (`dependabot-auto-merge.yml`): patch + minor only, plain `gh pr merge --merge` retried up to 6 times with jitter. Not `--auto`: `main` has no branch protection, so GitHub's auto-merge cannot be enabled, and the PRs opened in the same second used to knock each other out
- **Auto Deploy**: When `docker-compose.yml`, `config/config.yml.tmpl`, `render-config.py`, `deploy.sh` or anything under `host/` changes on `main`, the stack is deployed (config rendered first; `pangolin` restarted only if `config.yml` changed), then `host/install.sh` installs the host-side pieces (see "Host-side pieces" below)
- **Rollback** (`deploy.sh`): hot SQLite snapshot of `config/db/db.sqlite` to `/root/backups/pangolin/` before pulling, then a strict health check (all four services running, `pangolin` healthy, `https://pangolin.lupica.be/api/v1/` answering through gerbil + traefik). On failure: checkout back to the previous commit, DB restored **only if the pangolin image moved** (its migrations are irreversible), stack restarted, job failed → Telegram. ⚠️ `origin/main` still holds the bad commit: fix it in git, or the next deploy fails the same way.
- **Pre-upgrade DB copies**: `db.sqlite.prev` is replaced at every deploy, so when the pangolin image moves `deploy.sh` also keeps `/root/backups/pangolin/db.sqlite.pangolin-<old version>` (3 newest kept). That is the rollback point for an upgrade found bad *after* its deploy passed. Order matters: first, on the VPS, `docker compose stop pangolin`, copy that file over `config/db/db.sqlite` and delete `db.sqlite-wal` / `db.sqlite-shm`; only then push the commit that pins the old tag, and its deploy starts the old image on the restored DB. The other order starts the old image on the already-migrated DB.

### Manual Deployment

You can trigger a deployment manually from the GitHub Actions tab using the "Run workflow" button.

### Workflow Features

- SSH deployment to your server (Tailscale SSH, no stored key)
- Config-drift absorption before the pull (see below)
- Health check verification
- Automatic Docker image cleanup
- Concurrency control (prevents overlapping deployments)
- Telegram alert on failure (optional)

### Config drift

Pangolin rewrites `config/traefik/traefik_config.yml` every time it starts, to
pin the `badger` plugin version that ships with its image. The file is tracked,
so that rewrite leaves the deployment checkout permanently dirty, and a plain
`git pull` aborts with:

```
error: cannot pull with rebase: You have unstaged changes.
```

Under `set -e` that used to stop the whole deployment: Dependabot merged the
image bump, the workflow failed, and the server kept running the old images.

The deploy step now commits that drift (with `git add -u`, tracked files only —
never `git add -A`, since a new untracked runtime file could carry credentials)
and pushes it back, so it does not reappear at the next restart. The commit
touches only `config/`, and the workflow triggers on `docker-compose.yml`, so it
does not start another deployment.

## 🖥️ Host-side pieces (`host/`)

Things that live on the VPS itself rather than in a container. `host/install.sh`
installs them, idempotently, at the end of every deploy (after `deploy.sh`, so a
failure fails the job without rolling back a healthy stack). Files carry
`@REPO_DIR@`, replaced by the checkout path. By hand: `bash host/install.sh`.

### Stack start after a Docker restart

`pangolin-stack.service` runs `docker compose up -d --no-recreate` every time
`docker.service` starts or restarts (`WantedBy=` + `PartOf=docker.service`): at
boot, and when a `docker-ce` package upgrade restarts the daemon.

Traefik runs in gerbil's network namespace (`network_mode: service:gerbil`), and
Docker's restart policy does not bring such a container back after a daemon
restart. It logs nothing. On 2026-11-13 an `apt upgrade` moved `docker-ce`:
traefik stayed `Exited (0)`, through the reboot that followed, and every public
site was down until a manual `docker start traefik`. The newt tunnels reconnect
by themselves once Traefik answers.

`--no-recreate` keeps the unit from changing images or config: that stays the
job of `deploy.sh`. Check: `systemctl status pangolin-stack.service`.

### Traefik access-log rotation

`/etc/logrotate.d/pangolin-traefik`: `config/traefik/logs/access.log`, daily
(or at 500 MB), 30 rotations kept, gzip with `delaycompress`. Traefik reopens the
file on `USR1` (`postrotate`), and CrowdSec, which tails that file, follows the
path onto the new one (`Re-opening moved/deleted file` in its log). Before
2026-11-05 the file was never rotated and had reached 4.2 GB.

### CrowdSec allowlist for the newt sites (dynamic home IP)

**The failure it prevents.** newt calls `POST /api/v1/auth/newt/get-token`
every 3 s until it gets a token. If the home connection's IP is banned for any
reason, each retry gets a 403 from the bouncer (`ban.html`), and that stream of
403s triggers `LePresidente/http-generic-403-bf`, which bans the IP again. The
ban renews itself for as long as newt retries: both tunnels down, every public
site down, until someone deletes the decisions by hand.

It happened on 2026-11-05. Right after a Proxmox maintenance, a Home Assistant
dashboard panel received about 90 403s from HA itself within a minute, from the
home IP. `crowdsecurity/http-probing` banned that IP for 4 h. The newt pods
restarted during the ban, and the loop above kept it alive (71 alerts) until
`cscli decisions delete --ip`. Public sites were down for about 50 minutes.

**How it works.** The home IP is dynamic, so it is never written anywhere,
neither in this public repo nor in DNS. The VPS learns it by itself:

- Pangolin stores each site's public endpoint in `sites.endpoint`, with
  `lastHolePunch`. It is updated when gerbil relays newt's UDP hole punch,
  every few seconds. That path does not go through Traefik, so it keeps working
  while the IP is banned, and Pangolin only accepts it with the newt's session
  token.
- `crowdsec-newt-allowlist.timer` (every 5 min) runs
  `host/crowdsec-newt-allowlist.sh`. It reads that table **read-only** and keeps
  the CrowdSec allowlist `newt-sites` equal to the public IPs of the newt sites
  that punched in the last 10 minutes. It adds a new IP (and lifts any decision
  already active on it), and removes an IP no site uses any more.
- When no newt site has punched recently (tunnels down), the list is **left as
  is**: that is when it must keep holding the last known IP.
- After an IP change, the new IP is allowlisted at the next run (≤ 5 min).

An allowlisted IP cannot be banned: LAPI refuses the decision
(`cscli decisions add` → `is allowlisted by item … from newt-sites`). The
trade-off is deliberate: CrowdSec never blocks the home connection, including
any device on it.

```bash
docker exec crowdsec cscli allowlists inspect newt-sites   # current value(s)
docker exec crowdsec cscli allowlists check <IP>
journalctl -u crowdsec-newt-allowlist.service -n 20         # last runs
systemctl list-timers crowdsec-newt-allowlist.timer
```

⚠️ The script depends on Pangolin's schema (`sites.endpoint`,
`sites.lastHolePunch`, `sites.type`). If a Pangolin upgrade renames them, the
unit fails loudly instead of emptying the list: check the journal after a
Pangolin minor.

## 📁 Directory Structure

```
pangolin/
├── docker-compose.yml      # Main compose file
├── deploy.sh               # Snapshot, deploy, health check, rollback
├── host/                   # Installed on the VPS by host/install.sh
│   ├── install.sh
│   ├── crowdsec-newt-allowlist.sh
│   ├── logrotate/pangolin-traefik
│   └── systemd/            # crowdsec-newt-allowlist.{service,timer}, pangolin-stack.service
├── config/
│   ├── config.yml          # GENERATED by render-config.py (gitignored)
│   ├── config.yml.tmpl     # Versioned template, ${VAR} from .env
│   ├── GeoLite2-Country.mmdb
│   ├── key                 # Gerbil WireGuard key (auto-generated)
│   ├── db/
│   │   └── db.sqlite       # Pangolin database
│   ├── crowdsec/           # CrowdSec configuration
│   │   ├── config.yaml
│   │   ├── acquis.yaml
│   │   └── db/             # CrowdSec database
│   ├── traefik/
│   │   ├── traefik_config.yml
│   │   ├── dynamic_config.yml
│   │   ├── ban.html        # CrowdSec ban page
│   │   └── logs/           # Traefik access logs
│   └── letsencrypt/
│       └── acme.json       # Let's Encrypt certificates
└── README.md
```

## 🔒 Security Features

### CrowdSec Integration

This stack includes CrowdSec for:
- **Traefik log analysis**: Detects malicious patterns in web traffic
- **Virtual patching**: Protects against known CVEs
- **Generic rules**: Blocks SQL injection, XSS, and common attacks

### Traefik Security

- Automatic HTTPS with Let's Encrypt
- Modern TLS configuration
- IP whitelisting capability for admin interfaces

## 🔧 Maintenance

### View Logs

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f pangolin
docker compose logs -f crowdsec
```

### Update Images

```bash
docker compose pull
docker compose up -d
```

### Backup

Important files to backup:
- `config/config.yml` - Your configuration
- `config/db/db.sqlite` - Pangolin database
- `config/letsencrypt/acme.json` - SSL certificates

### CrowdSec Commands

```bash
# View decisions (bans)
docker exec crowdsec cscli decisions list

# View alerts
docker exec crowdsec cscli alerts list

# Unban an IP
docker exec crowdsec cscli decisions delete --ip <IP_ADDRESS>

# Home IP allowlist (managed by host/crowdsec-newt-allowlist.sh, do not edit by hand)
docker exec crowdsec cscli allowlists inspect newt-sites
```

## 🐛 Troubleshooting

### Container Health

```bash
docker compose ps
docker compose logs <service-name>
```

### Certificate Issues

If Let's Encrypt certificates aren't being issued:
1. Ensure ports 80 and 443 are accessible
2. Verify DNS is correctly pointing to your server
3. Check Traefik logs: `docker compose logs traefik`

### CrowdSec False Positives

If legitimate traffic is being blocked:
```bash
# Check what triggered the ban
docker exec crowdsec cscli alerts list

# Whitelist an IP
docker exec crowdsec cscli decisions delete --ip <IP_ADDRESS>
```

## 📚 Documentation

- [Pangolin Docs](https://docs.pangolin.net/)
- [Traefik Docs](https://doc.traefik.io/traefik/)
- [CrowdSec Docs](https://docs.crowdsec.net/)

## 📝 License

This configuration is provided as-is for personal use.
