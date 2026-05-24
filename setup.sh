#!/bin/bash
set -e

echo ""
echo "=========================================="
echo "  Self-Hosted n8n Stack — Setup"
echo "=========================================="
echo ""

# --- Check required commands ---
for cmd in free nproc openssl docker; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: '$cmd' is not installed. Please install it and re-run setup."
        exit 1
    fi
done

if ! docker compose version &> /dev/null; then
    echo "Error: Docker Compose v2 is required ('docker compose', not 'docker-compose')."
    echo "Install Docker 20.10+ which includes it by default."
    exit 1
fi

# --- Detect hardware ---
echo "Detecting system resources..."
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
TOTAL_CORES=$(nproc)
echo "  RAM: ${TOTAL_RAM_MB}MB | Cores: ${TOTAL_CORES}"
echo ""

if [ "$TOTAL_RAM_MB" -lt 1800 ]; then
    echo "Error: This stack requires at least 2GB RAM. Detected ${TOTAL_RAM_MB}MB."
    exit 1
fi

AVAILABLE_MB=$((TOTAL_RAM_MB - 256))

# --- Collect configuration ---
echo "--- Configuration ---"
echo ""

# Domain
read -p "Domain name (e.g. srv123.hstgr.cloud): " DOMAIN_NAME
while [ -z "$DOMAIN_NAME" ]; do
    echo "  Domain name is required."
    read -p "Domain name: " DOMAIN_NAME
done

# Subdomain — fixed
SUBDOMAIN=n8n

# SSL email
read -p "Email address (for SSL certificate notices): " SSL_EMAIL
while [ -z "$SSL_EMAIL" ]; do
    echo "  Email is required."
    read -p "Email address: " SSL_EMAIL
done

# Postgres password
echo ""
GENERATED_PG_PASS=$(openssl rand -hex 16)
echo "Generated Postgres password: ${GENERATED_PG_PASS}"
read -p "Use this? [Y/n]: " USE_PG
if [[ "$USE_PG" =~ ^[Nn]$ ]]; then
    read -p "Enter your own Postgres password: " POSTGRES_PASSWORD
    while [ -z "$POSTGRES_PASSWORD" ]; do
        read -p "  Password cannot be empty: " POSTGRES_PASSWORD
    done
else
    POSTGRES_PASSWORD=$GENERATED_PG_PASS
fi

# n8n encryption key
echo ""
GENERATED_KEY=$(openssl rand -hex 32)
echo "Generated n8n encryption key: ${GENERATED_KEY}"
read -p "Use this? [Y/n]: " USE_KEY
if [[ "$USE_KEY" =~ ^[Nn]$ ]]; then
    read -p "Enter your own encryption key: " N8N_ENCRYPTION_KEY
    while [ -z "$N8N_ENCRYPTION_KEY" ]; do
        read -p "  Key cannot be empty: " N8N_ENCRYPTION_KEY
    done
else
    N8N_ENCRYPTION_KEY=$GENERATED_KEY
fi

# Watchtower notifications (optional)
echo ""
read -p "Watchtower notification URL (leave empty to skip): " WATCHTOWER_NOTIFICATION_URL

# --- Calculate resource limits ---
# Fixed allocations for lightweight services
TRAEFIK_MB=128
WATCHTOWER_MB=64
REDIS_MB=128

# Scaled allocations for heavier services
POSTGRES_MB=$((AVAILABLE_MB * 20 / 100))
N8N_MB=$((AVAILABLE_MB * 25 / 100))

[ $POSTGRES_MB -lt 256 ] && POSTGRES_MB=256
[ $N8N_MB -lt 256 ]      && N8N_MB=256

# Workers get everything left — minimum 512MB per worker, cap at 10
FIXED_TOTAL=$((256 + TRAEFIK_MB + WATCHTOWER_MB + REDIS_MB + POSTGRES_MB + N8N_MB))
WORKER_BUDGET=$((TOTAL_RAM_MB - FIXED_TOTAL))
N8N_WORKER_COUNT=$((WORKER_BUDGET / 512))
[ $N8N_WORKER_COUNT -lt 1 ]  && N8N_WORKER_COUNT=1
[ $N8N_WORKER_COUNT -gt 10 ] && N8N_WORKER_COUNT=10
WORKER_MB=$((WORKER_BUDGET / N8N_WORKER_COUNT))

echo ""
echo "Resource allocation:"
echo "  n8n:        ${N8N_MB}MB"
echo "  Workers:    ${WORKER_MB}MB each × ${N8N_WORKER_COUNT} = $((WORKER_MB * N8N_WORKER_COUNT))MB total"
echo "  Postgres:   ${POSTGRES_MB}MB"
echo "  Redis:      ${REDIS_MB}MB"
echo "  Traefik:    ${TRAEFIK_MB}MB"
echo "  Watchtower: ${WATCHTOWER_MB}MB"

# --- Write .env ---
echo ""
echo "Writing .env..."

# Write .env — use printf for user-provided values to safely handle special characters
{
    echo "# Domain"
    printf 'DOMAIN_NAME=%s\n' "$DOMAIN_NAME"
    printf 'SUBDOMAIN=%s\n'   "$SUBDOMAIN"
    printf 'SSL_EMAIL=%s\n'   "$SSL_EMAIL"
    echo ""
    echo "# Postgres"
    echo "POSTGRES_USER=n8n"
    printf 'POSTGRES_PASSWORD=%s\n' "$POSTGRES_PASSWORD"
    echo "POSTGRES_DB=n8n_db"
    echo ""
    echo "# n8n"
    printf 'N8N_ENCRYPTION_KEY=%s\n' "$N8N_ENCRYPTION_KEY"
    echo "EXECUTIONS_DATA_MAX_AGE=168"
    echo ""
    echo "# Workers"
    echo "N8N_WORKER_COUNT=${N8N_WORKER_COUNT}"
    echo ""
    echo "# Watchtower"
    printf 'WATCHTOWER_NOTIFICATION_URL=%s\n' "$WATCHTOWER_NOTIFICATION_URL"
    echo ""
    echo "# Resource limits — auto-allocated (${TOTAL_RAM_MB}MB RAM, ${TOTAL_CORES} cores, ${N8N_WORKER_COUNT} workers)"
    echo "TRAEFIK_MEMORY_LIMIT=${TRAEFIK_MB}m"
    echo "TRAEFIK_CPU_LIMIT=0.5"
    echo "POSTGRES_MEMORY_LIMIT=${POSTGRES_MB}m"
    echo "POSTGRES_CPU_LIMIT=1"
    echo "REDIS_MEMORY_LIMIT=${REDIS_MB}m"
    echo "REDIS_CPU_LIMIT=0.5"
    echo "N8N_MEMORY_LIMIT=${N8N_MB}m"
    echo "N8N_CPU_LIMIT=1"
    echo "N8N_WORKER_MEMORY_LIMIT=${WORKER_MB}m"
    echo "N8N_WORKER_CPU_LIMIT=1"
    echo "WATCHTOWER_MEMORY_LIMIT=${WATCHTOWER_MB}m"
    echo "WATCHTOWER_CPU_LIMIT=0.5"
} > .env

# --- Remind user to save credentials ---
echo ""
echo "=========================================="
echo "  IMPORTANT — Save these credentials now"
echo "=========================================="
printf '  Postgres password:   %s\n' "$POSTGRES_PASSWORD"
printf '  n8n encryption key:  %s\n' "$N8N_ENCRYPTION_KEY"
echo ""
echo "  Store both in a password manager."
echo "  If you lose the encryption key, all stored"
echo "  credentials in n8n cannot be recovered."
echo "=========================================="
echo ""

# --- Start the stack ---
read -p "Start the stack now? [Y/n]: " START_STACK
if [[ ! "$START_STACK" =~ ^[Nn]$ ]]; then
    echo ""
    echo "Starting stack..."
    docker compose up -d
    echo ""
    echo "Done. n8n will be ready in ~60-90 seconds."
    echo "Access it at: https://${SUBDOMAIN}.${DOMAIN_NAME}"
    echo ""
    echo "Run 'docker compose ps' to check service status."
else
    echo ""
    echo "Run 'docker compose up -d' when ready."
    echo "n8n will be at: https://${SUBDOMAIN}.${DOMAIN_NAME}"
fi
