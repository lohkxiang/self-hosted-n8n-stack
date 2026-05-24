# Self-Hosted n8n Stack

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![GitHub release](https://img.shields.io/github/v/release/lohkxiang/self-hosted-n8n-stack)](https://github.com/lohkxiang/self-hosted-n8n-stack/releases/latest)

Build and host your own AI agent — no execution limits, no vendor lock-in.

Built around [n8n](https://n8n.io), an open-source workflow automation tool. n8n cloud plans cap monthly executions by tier; self-hosting removes that cap. You pay for your VPS, nothing else.

The trade-off is ownership — you're responsible for keeping the stack running, applying updates, and managing backups. If you'd prefer not to handle that, [n8n Cloud](https://n8n.io/cloud/) takes care of it for you.

---

## Architecture

```
Internet
       │ HTTPS (secure web traffic)
       ▼
  Traefik
  └── Handles SSL and routes traffic to n8n
       │
       ▼
  n8n — Agent & Workflow Engine
  ├── Receives triggers and webhooks
  └── Manages and runs your AI agent workflows
       │                        │
       ▼                        ▼
  Postgres                  Redis Queue
  └── Stores workflows,     └── Passes jobs to workers
      credentials,               │
      data and history           ▼
                            n8n Workers
                            └── Execute workflows
                                 and call AI models / APIs

  Watchtower
  └── Monitors all containers — alerts when updates are available
```

---

## Stack

| Service | Purpose |
|---|---|
| n8n | Workflow automation — build and run your AI agent |
| n8n Worker | Executes workflows independently, enabling concurrent processing |
| Postgres | Stores all workflows, credentials, execution history and data |
| Redis | Manages the job queue between n8n and workers — queue is persisted to disk, survives restarts |
| Traefik | Handles SSL certificates and routes web traffic securely |
| Watchtower | Monitors containers for image updates — never auto-updates |

> Designed to run on a **VPS**. Uses your VPS provider's default hostname — no custom domain needed. Not intended for local-only use.

---

## Prerequisites

- **A VPS** — a remote server you rent from a hosting provider, think of it as your own computer in the cloud running 24/7. Recommended providers: [Hostinger](https://hostinger.com), [DigitalOcean](https://digitalocean.com), [Hetzner](https://hetzner.com), [Vultr](https://vultr.com). Minimum spec: **2GB RAM, 1 vCPU, 20GB disk** — this runs the full stack with 1 worker. 4GB+ recommended if you plan to run multiple workflows concurrently.
- **Your VPS hostname** — your provider assigns this automatically (e.g. `srv123.hstgr.cloud`). No custom domain needed.
- **Docker installed on your VPS** — most VPS providers let you install it in one command. This stack requires **Docker Compose v2** (`docker compose`, not `docker-compose`) — included by default with Docker 20.10+.
- **Ports 80 and 443 open** — open these in your VPS provider's firewall or network settings.

---

## Setup

1. Clone the repo on your VPS:
   ```bash
   git clone https://github.com/lohkxiang/self-hosted-n8n-stack.git
   cd self-hosted-n8n-stack
   ```

2. Run the setup script:
   ```bash
   chmod +x setup.sh && ./setup.sh
   ```
   The script will:
   - Detect your VPS RAM and CPU and auto-allocate resource limits for every service
   - Prompt you for your domain, email, and optionally a Watchtower notification URL
   - Generate secure passwords and encryption keys automatically — these are displayed at the end, save them in a password manager. If you miss them, SSH into your VPS and run `cat .env` to retrieve them
   - Write everything to `.env`
   - Start the stack

That's it. n8n will be ready in ~60–90 seconds. Your final URL will be `https://n8n.[your-hostname]` — e.g. `https://n8n.srv123.hstgr.cloud`. Complete the setup wizard on first visit.

**Common commands after setup:**

| Task | Command |
|------|---------|
| Check service status | `docker compose ps` |
| View logs | `docker compose logs -f` |
| Stop the stack | `docker compose down` |
| Restart the stack | `docker compose up -d` |
| Edit your configuration | `nano .env` |
| Back up the database | `docker compose exec postgres pg_dump -U n8n n8n_db > backup_$(date +%Y%m%d).sql` |
| Automate database backups | See [Database Maintenance](#database-maintenance) |

---

## Traefik and SSL

Traefik handles two things automatically — no separate config files needed:

- **SSL certificates** — issued by [Let's Encrypt](https://letsencrypt.org) on first startup, renewed automatically. Let's Encrypt is free — you do not need to purchase an SSL certificate from your VPS provider.
- **Routing** — forwards HTTPS traffic to n8n based on your hostname

Your VPS provider assigns you a default hostname (e.g. `srv123.hstgr.cloud`) that's already publicly resolvable. Enter it when setup.sh prompts for your domain — no DNS configuration needed.

---

## Concurrency and Scaling

This stack runs n8n in **queue mode** — here's why it matters:

By default, n8n handles everything in a single process. Under load, a heavy workflow can block new triggers from being processed. Queue mode splits this into two roles:

```
  n8n (main)
  ├── Receives all triggers and webhooks
  └── Pushes jobs to Redis Queue
           │
           ▼
      Redis Queue
      └── Holds pending executions
           │
     ┌─────┴─────┐
     ▼           ▼
  Worker 1   Worker 2  ...
  └── Picks up and executes jobs independently
```

**How many workers should you run?**

The setup script calculates this automatically — you don't need to choose. It allocates remaining RAM after all other services are provisioned, fits as many workers as possible at 512MB minimum each, then caps at twice your core count to avoid CPU contention. Re-run `./setup.sh` if you move to a larger VPS.

---

## Healthchecks and Startup Order

Each service has a healthcheck — a small test that runs periodically to confirm it's actually working, not just running. Docker won't start the next service until the previous one passes.

The startup sequence is:

```
Postgres → Redis → n8n (main) → n8n Workers
```

First startup can take 60–90 seconds. If you check too early you'll get a connection error — just wait and refresh. Use `docker compose ps` to check status at any time.

---

## Resource Limits

Every service has a memory and CPU ceiling to prevent a single container from consuming the whole server. The setup script calculates and sets these automatically based on your VPS RAM:

| Service | Memory allocation | CPU |
|---------|------------------|-----|
| n8n | 25% of RAM | 1 core |
| n8n Worker | remaining RAM ÷ workers | 1 core |
| Postgres | 20% of RAM | 1 core |
| Redis | 128MB fixed | 0.5 cores |
| Traefik | 128MB fixed | 0.5 cores |
| Watchtower | 64MB fixed | 0.5 cores |

---

## Webhooks and CORS

n8n exposes webhooks at:
```
https://n8n.[your-hostname]/webhook/[your-path]
```

Point external services (Slack, GitHub, payment providers, etc.) to this URL to trigger your workflows. These are server-to-server calls — CORS doesn't apply.

CORS only matters if you're calling n8n webhooks directly from a browser-based frontend. In that case, add to the `n8n` service in `docker-compose.yml`:

```yaml
- N8N_CORS_ENABLED=true
- N8N_CORS_ALLOWED_ORIGINS=https://yourdomain.com
```

Use `*` during development only — not for production.

---

## Keeping Your Stack Up to Date

**Watchtower** runs in monitor-only mode — checks daily for image updates but never applies them automatically. You set the notification URL during setup. To change it later, run `nano .env`, update `WATCHTOWER_NOTIFICATION_URL`, and run `docker compose up -d`. For Gmail SMTP credentials, follow [this guide](https://support.google.com/accounts/answer/185833).

---

## Database Maintenance

**Execution pruning** — n8n logs every workflow execution in Postgres. This stack enables pruning by default, retaining executions for 168 hours (7 days). Adjust `EXECUTIONS_DATA_MAX_AGE` in `.env` if needed.

**Backups** — your workflows, credentials, and execution history all live in Postgres. Back it up regularly.

**Option 1 — manual** (run on demand):
```bash
docker compose exec postgres pg_dump -U n8n n8n_db > backup_$(date +%Y%m%d).sql
```

**Option 2 — automated** (runs daily at 2am via cron):
```bash
0 2 * * * docker compose -f /path/to/docker-compose.yml exec -T postgres pg_dump -U n8n n8n_db > /home/user/backup_$(date +\%Y\%m\%d).sql
```
Add this to your VPS crontab with `crontab -e`. Replace `/path/to/docker-compose.yml` with the full path to your repo.

---

## Security Best Practices

- **Never commit your `.env` file** — it stays on your VPS only, never in the repo.
- **Disable root login on your VPS** — most providers let you do this in their control panel.
- **Back up your `N8N_ENCRYPTION_KEY`** — n8n uses this to encrypt all stored credentials. If lost, those credentials cannot be recovered. Store it in a password manager.
- **Only open the ports you need** — ports 80 and 443 for web traffic, nothing else.

---

## Going Further

**Staging and production** — run two instances of this stack on separate VPS servers (or in separate directories on the same server), each with their own `.env`.

**Secrets management** — `.env` files are fine for most use cases. For stronger secrets management (team access, rotation, audit logs), look into HashiCorp Vault or AWS Secrets Manager.

---

## Troubleshooting

**A container keeps restarting**

Containers restart silently in the background — there is no built-in notification. The simplest way to get alerted is to set up a free [UptimeRobot](https://uptimerobot.com) monitor pointing at your n8n URL — it pings every 5 minutes and emails you if it goes down.

To manually check status at any time:

```bash
docker compose ps
```

A container showing `Restarting` has likely hit its memory limit. Check its logs to confirm:

```bash
docker compose logs <service-name>
```

Fix: move to a larger VPS and re-run `./setup.sh` — it recalculates all limits from scratch based on your new RAM and restarts the stack. Avoid manually editing individual memory limits in `.env` unless you understand the full allocation — the limits are balanced across all services and changing one in isolation can cause the total to exceed available RAM.

**n8n is not accessible after startup**

First startup takes 60–90 seconds. If it's still not accessible after that, check service status with `docker compose ps` and look for any unhealthy or restarting containers.

**SSL certificate not issuing**

Let's Encrypt verifies ownership by making a TLS connection to your hostname on port 443. Make sure port 443 is open in your VPS provider's firewall before running setup. If issuance failed, run `docker compose up -d` to retry.

---

## Need Help?

Built this for your own setup and got stuck? [Get in touch](https://lohkaixiang.com).
