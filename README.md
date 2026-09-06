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

# Create your configuration file
cp config/config.yml.example config/config.yml

# Create your environment file
cp .env.example .env

# Edit the configuration with your values
nano config/config.yml
nano .env
```

### 2. Configure Your Settings

#### Environment Variables
Edit `.env` and set:
- `CROWDSEC_LAPI_KEY`: Get this by running `docker exec crowdsec cscli bouncers add traefik-bouncer`
- `LETS_ENCRYPT_EMAIL`: Your email address for SSL certificate notifications
- `PANGOLIN_DOMAIN`: The domain where Pangolin is hosted (e.g. `pangolin.example.com`)

#### Application Config
Edit `config/config.yml` and update:

- **Domain settings**: Replace `your-domain.com` with your actual domain
- **Server secret**: Generate a secure random string (`openssl rand -base64 24`)
- **Email settings**: Configure SMTP for email verification

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

## 🔄 CI/CD

This repository includes automated deployment via GitHub Actions:

- **Dependabot**: Checks for Docker image updates weekly (Sundays 2:00 AM)
- **Auto Deploy**: When `docker-compose.yml` changes are pushed to `main`, the stack is automatically deployed

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

## 📁 Directory Structure

```
pangolin/
├── docker-compose.yml      # Main compose file
├── config/
│   ├── config.yml          # Main Pangolin configuration (gitignored)
│   ├── config.yml.example  # Template configuration
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
