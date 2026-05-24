# Self-Hosted n8n Stack

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

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
| Redis | Manages the job queue between n8n and workers |
| Traefik | Handles SSL certificates and routes web traffic securely |
| Watchtower | Monitors containers for image updates — never auto-updates |

> Designed to run on a **VPS**. A custom domain is optional — your VPS provider's default hostname works out of the box. Not intended for local-only use.

---

## Prerequisites

- **A VPS** — a remote server you rent from a hosting provider, think of it as your own computer in the cloud running 24/7. Recommended providers: [Hostinger](https://hostinger.com), [DigitalOcean](https://digitalocean.com), [Hetzner](https://hetzner.com), [Vultr](https://vultr.com)
- **A domain name** *(optional)* — your VPS provider assigns you a default hostname (e.g. `srv123.hstgr.cloud`) which works out of the box. You can also use your own custom domain if you have one. This is what your agent will be accessible from.
- **Docker installed on your VPS** — Docker is the technology that runs all the services in this stack. Most VPS providers let you install it in one command. This stack requires **Docker Compose v2** (`docker compose`, not `docker-compose`) — included by default with Docker 20.10+.
- **Ports 80 and 443 open** — these are the standard web ports that allow your agent to be reached from the internet and for SSL to work. You can open them in your VPS provider's control panel under firewall or network settings.

---

## Setup

1. Open your VPS terminal and clone this repo:
   ```bash
   git clone https://github.com/lohkxiang/self-hosted-n8n-stack.git
   cd self-hosted-n8n-stack
   ```

2. Create your `.env` file directly on the VPS and fill in your values:
   ```bash
   cp .env.example .env
   nano .env
   ```
   Key values to fill in:
   - `DOMAIN_NAME` — your VPS default hostname (e.g. `srv123.hstgr.cloud`) or your own domain
   - `SUBDOMAIN` — what comes before the domain (e.g. `n8n` gives you `n8n.srv123.hstgr.cloud`)
   - `SSL_EMAIL` — your email address, used by Let's Encrypt to notify you before your SSL certificate expires
   - `POSTGRES_PASSWORD` and `N8N_ENCRYPTION_KEY` — use strong, unique values

   Save the file. It stays on your VPS only and is never committed to the repo.

3. Start the stack:
   ```bash
   docker compose up -d
   ```

4. Access n8n at `https://[your-subdomain].[your-domain]` (e.g. `https://n8n.srv123.hstgr.cloud`) and complete the setup wizard.

---

## Traefik and SSL

Traefik is fully configured via the compose file — no separate config files needed. It handles two things automatically:

- **SSL certificates** — issued by Let's Encrypt on first startup, renewed automatically before they expire
- **Routing** — forwards HTTPS traffic to n8n based on your domain

**Using your VPS default hostname** — works out of the box. No DNS changes needed.

**Using a custom domain** — point an A record at your VPS IP address before starting the stack. Let's Encrypt verifies domain ownership via HTTP, so the DNS record needs to resolve before you run `docker compose up -d`, otherwise SSL issuance fails.

---

## Concurrency and Scaling

This stack runs n8n in **queue mode** — here's why it matters:

By default, n8n handles everything in a single process: receiving triggers, managing workflows, and executing them. Under load, a heavy workflow can block new triggers from being processed.

Queue mode splits this into two roles:

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

Each worker runs independently — add more workers to handle more concurrent executions.

**How many workers should you run?**

Each worker uses approximately 500MB of RAM. A rough guide:

| VPS RAM | Recommended Workers |
|---------|-------------------|
| 2GB | 1 |
| 4GB | 2–3 |
| 8GB | 5–6 |
| 16GB | 10+ |

Set your worker count in `.env`:
```
N8N_WORKER_COUNT=3
```

Then run:
```bash
docker compose up -d
```

This works whether you're starting fresh or updating an already running stack — if you change `N8N_WORKER_COUNT` later, just run `docker compose up -d` again to apply.

---

## Webhooks and CORS

n8n exposes webhooks at:
```
https://[your-subdomain].[your-domain]/webhook/[your-path]
```

Point external services (Slack, GitHub, payment providers, etc.) to this URL to trigger your workflows.

If you're calling n8n webhooks directly from a browser-based frontend, you'll hit CORS errors by default. Add these environment variables to the `n8n` service in your compose file:

```yaml
- N8N_CORS_ENABLED=true
- N8N_CORS_ALLOWED_ORIGINS=https://yourdomain.com
```

Replace `https://yourdomain.com` with the origin making the request. Use `*` to allow all origins during development only — not for production use.

---

## Keeping Your Stack Up to Date

**Watchtower** runs in monitor-only mode — it checks daily for image updates but never applies them automatically. To receive email notifications when updates are available, set `WATCHTOWER_NOTIFICATION_URL` in your `.env` (see `.env.example` for the format). If left empty, Watchtower runs silently. For Gmail SMTP credentials, follow [this guide](https://support.google.com/accounts/answer/185833).

---

## Database Maintenance

**Execution pruning** — n8n logs every workflow execution in Postgres. Without pruning, your database grows indefinitely. This stack enables pruning by default, retaining executions for the number of hours set in `EXECUTIONS_DATA_MAX_AGE` (default: 168 hours / 7 days). Adjust in `.env` if needed.

**Backing up Postgres** — your workflows, credentials, and execution history all live in Postgres. Back it up regularly:

```bash
docker compose exec postgres pg_dump -U n8n n8n_db > backup_$(date +%Y%m%d).sql
```

Replace `n8n` and `n8n_db` with your `POSTGRES_USER` and `POSTGRES_DB` values if you changed them. Store the backup somewhere safe — your local machine, an S3 bucket, or a separate storage service. To automate, add a cron job on your VPS:

```bash
0 2 * * * docker compose -f /path/to/docker-compose.yml exec -T postgres pg_dump -U n8n n8n_db > /home/user/backup_$(date +\%Y\%m\%d).sql
```

---

## Security Best Practices

- **Never commit your `.env` file** — it contains passwords and secret keys. Always create it directly on your VPS, never on your local machine or in the repo.
- **Disable root login on your VPS** — most VPS providers let you do this in their control panel or security settings. This prevents attackers from trying to guess your password.
- **Use strong, unique passwords** for `POSTGRES_PASSWORD` and `N8N_ENCRYPTION_KEY` — don't reuse passwords from other services.
- **Back up your `N8N_ENCRYPTION_KEY`** — n8n uses this to encrypt all stored credentials (API keys, passwords, tokens). If lost, those credentials cannot be recovered. Store it in a password manager alongside your database backups.
- **Only open the ports you need** — ports 80 and 443 for web traffic, nothing else.

---

## Going Further

This stack is intentionally a starting point. A few things worth knowing as you grow:

**Staging and production** — if you want separate environments, run two instances of this stack on separate VPS servers (or in separate directories on the same server), each with their own `.env`. There's no built-in environment separation — it's just separate deployments.

**Secrets management** — `.env` files are the simplest approach and fine for most use cases. If you need stronger secrets management (team access, rotation, audit logs), look into a dedicated secrets manager like HashiCorp Vault or AWS Secrets Manager.

---

## Need Help?

Built this for your own setup and got stuck? [Get in touch](https://lohkaixiang.com).
