# Uptime Kuma — Docker Compose Setup

Uptime Kuma monitoring stack with MariaDB and Nginx SSL reverse proxy.

---

## Project Structure

```
project/
├── .env                        # Passwords and DB credentials  ← edit this
├── docker-compose.yml          # Service definitions
├── deploy.sh                   # Deploy helper script
└── nginx/
    ├── default.conf            # Nginx config (FQDN lives here) ← edit this
    └── certs/
        ├── tls.crt             # Your SSL certificate           ← place here
        └── tls.key             # Your SSL private key           ← place here
```

---

## Quick Start

### 1. Clone or copy the project files

Place all files following the structure above.

### 2. Set your passwords

Open **`.env`** and change every value:

```env
# ── MariaDB ─────────────────────────────────────────
MARIADB_ROOT_PASSWORD=rootpassword    # ← change this
MARIADB_DATABASE=uptimekuma
MARIADB_USER=kuma
MARIADB_PASSWORD=kumapass             # ← change this

# ── Uptime Kuma → DB connection ─────────────────────
KU_DB_TYPE=mysql
KU_DB_HOST=kuma-db
KU_DB_PORT=3306
KU_DB_NAME=uptimekuma
KU_DB_USER=kuma
KU_DB_PASSWORD=kumapass               # ← must match MARIADB_PASSWORD above
```

> **Rule:** `KU_DB_PASSWORD` must always match `MARIADB_PASSWORD`.

### 3. Set your domain (FQDN)

Open **`nginx/default.conf`** and replace the domain in two places:

```nginx
server {
    listen 443 ssl;
    server_name kuma.domain.com;    # ← change to your domain
    ...
}

server {
    listen 80;
    server_name kuma.domain.com;    # ← change to your domain
    ...
}
```

### 4. Place your SSL certificates

Copy your certificate files into `nginx/certs/`:

```
nginx/certs/tls.crt    ← full chain certificate
nginx/certs/tls.key    ← private key
```

> If you don't have a certificate yet, see [Get a free SSL certificate](#get-a-free-ssl-certificate) below.

### 5. Deploy

```bash
chmod +x deploy.sh
./deploy.sh up
```

Uptime Kuma will be available at `https://kuma.domain.com`.

---

## Deploy Commands

```bash
./deploy.sh up               # Pull images and start all services (first run)
./deploy.sh update           # Pull latest images and recreate services
./deploy.sh rolling          # Zero-downtime rolling update (all services)
./deploy.sh rolling kuma-app # Zero-downtime update for one service only
./deploy.sh down             # Stop all services
./deploy.sh restart          # Restart all services
./deploy.sh logs             # Follow logs (all services)
./deploy.sh logs kuma-app    # Follow logs for one service
./deploy.sh status           # Show running containers
./deploy.sh destroy          # Stop everything and delete all data volumes
```

---

## Services

| Container | Image | Purpose | Port |
|---|---|---|---|
| `kuma-db` | `mariadb:11` | Database | internal only |
| `kuma-app` | `louislam/uptime-kuma:2` | Monitoring app | internal (3001) |
| `kuma-nginx` | `nginx:alpine` | SSL reverse proxy | 80, 443 |

Startup order is enforced automatically:
```
kuma-db  →  kuma-app  →  kuma-nginx
```
Each service waits for the previous one to pass its health check before starting.

---

## Customisation Reference

### Change the domain

File: `nginx/default.conf`

```nginx
server_name kuma.your-domain.com;   # update both server blocks
```

### Change passwords

File: `.env`

```env
MARIADB_PASSWORD=your_new_password
KU_DB_PASSWORD=your_new_password    # keep in sync with above
MARIADB_ROOT_PASSWORD=your_root_password
```

After changing passwords on a fresh install, just re-run `./deploy.sh up`.
If the database already exists, you must also update the password inside MariaDB:

```bash
docker exec -it kuma-db mariadb -u root -p
ALTER USER 'kuma'@'%' IDENTIFIED BY 'your_new_password';
FLUSH PRIVILEGES;
```

### Change the Uptime Kuma version

File: `docker-compose.yml`

```yaml
kuma-app:
  image: louislam/uptime-kuma:2      # pin to a specific version e.g. 2.2.0
```

### Change the MariaDB version

File: `docker-compose.yml`

```yaml
kuma-db:
  image: mariadb:11                  # e.g. mariadb:10.11 for LTS
```

### Change the listening ports

File: `docker-compose.yml`

```yaml
kuma-nginx:
  ports:
    - "80:80"      # host_port:container_port
    - "443:443"
```

---

## Get a Free SSL Certificate

If you don't have a certificate, use [Certbot](https://certbot.eff.org/) with Let's Encrypt:

```bash
# Install certbot
apt install certbot

# Issue certificate (DNS must point to this server first)
certbot certonly --standalone -d kuma.your-domain.com

# Certificates will be at:
# /etc/letsencrypt/live/kuma.your-domain.com/fullchain.pem  → tls.crt
# /etc/letsencrypt/live/kuma.your-domain.com/privkey.pem    → tls.key

# Copy to project
cp /etc/letsencrypt/live/kuma.your-domain.com/fullchain.pem nginx/certs/tls.crt
cp /etc/letsencrypt/live/kuma.your-domain.com/privkey.pem   nginx/certs/tls.key
```

---

## Data & Backups

Persistent data is stored in Docker named volumes:

| Volume | Contents |
|---|---|
| `db-data` | MariaDB database files |
| `kuma-data` | Uptime Kuma config and monitor data |

### Backup

```bash
# Backup database
docker exec kuma-db mariadb-dump -u root -p${MARIADB_ROOT_PASSWORD} uptimekuma \
  > backup_$(date +%F).sql

# Backup Uptime Kuma data
docker run --rm \
  -v kuma-data:/data \
  -v $(pwd):/backup \
  alpine tar czf /backup/kuma-data_$(date +%F).tar.gz /data
```

### Restore

```bash
# Restore database
docker exec -i kuma-db mariadb -u root -p${MARIADB_ROOT_PASSWORD} uptimekuma \
  < backup_2026-01-01.sql
```

---

## Troubleshooting

### nginx: host not found in upstream "kuma-app"

Nginx started before `kuma-app` was ready. The config uses Docker's internal DNS resolver (`127.0.0.11`) with a variable upstream to handle this gracefully. If it still happens, restart nginx:

```bash
docker restart kuma-nginx
```

### Uptime Kuma cannot connect to database

Check that `.env` credentials match, then verify the DB is healthy:

```bash
./deploy.sh logs kuma-db
./deploy.sh status
```

### View logs for a specific service

```bash
./deploy.sh logs kuma-db
./deploy.sh logs kuma-app
./deploy.sh logs kuma-nginx
```

### Reset everything (destructive)

```bash
./deploy.sh destroy    # removes containers AND volumes (all data lost)
./deploy.sh up
```
