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

## Step 1 — Install Docker & Docker Compose

Skip this section if Docker is already installed. Verify with:

```bash
docker --version
docker compose version
```

### Ubuntu / Debian

**1. Remove old versions**
```bash
sudo apt remove docker docker-engine docker.io containerd runc 2>/dev/null
```

**2. Install dependencies**
```bash
sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release
```

**3. Add Docker's official GPG key**
```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
```

**4. Add Docker repository**
```bash
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

**5. Install Docker Engine and Compose plugin**
```bash
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

**6. Start Docker and allow running without sudo**
```bash
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
newgrp docker   # apply group change without logging out
```

---

### CentOS / RHEL / Rocky Linux

**1. Remove old versions**
```bash
sudo yum remove docker docker-client docker-client-latest \
  docker-common docker-latest docker-latest-logrotate \
  docker-logrotate docker-engine 2>/dev/null
```

**2. Add Docker repository**
```bash
sudo yum install -y yum-utils
sudo yum-config-manager \
  --add-repo https://download.docker.com/linux/centos/docker-ce.repo
```

**3. Install Docker Engine and Compose plugin**
```bash
sudo yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

**4. Start Docker and allow running without sudo**
```bash
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
newgrp docker   # apply group change without logging out
```

---

### Verify Installation

```bash
docker --version
docker compose version
```

Expected output:
```
Docker version 27.x.x, build xxxxxxx
Docker Compose version v2.x.x
```

> **Note:** This stack requires **Docker Compose v2** (`docker compose` with a space).
> The deploy script supports both v1 and v2 but v2 is recommended.

---

## Step 2 — Configure the Project

### 1. Copy project files

Place all files on your server following the project structure above.

```bash
# Example — copy from local machine to server
scp -r ./project user@your-server:/opt/uptime-kuma
```

Or clone if hosted in a git repo:

```bash
git clone https://your-repo-url.git /opt/uptime-kuma
cd /opt/uptime-kuma
```

### 2. Set passwords

Open **`.env`** and change every credential:

```env
# ── MariaDB ──────────────────────────────────────────────────
MARIADB_ROOT_PASSWORD=rootpassword    # ← change this
MARIADB_DATABASE=uptimekuma
MARIADB_USER=kuma
MARIADB_PASSWORD=kumapass             # ← change this

# ── Uptime Kuma → DB connection ──────────────────────────────
KU_DB_TYPE=mysql
KU_DB_HOST=kuma-db
KU_DB_PORT=3306
KU_DB_NAME=uptimekuma
KU_DB_USER=kuma
KU_DB_PASSWORD=kumapass               # ← must match MARIADB_PASSWORD above
```

> ⚠️ **Rule:** `KU_DB_PASSWORD` must always be identical to `MARIADB_PASSWORD`.
> Mismatch causes `Access denied` on startup.

### 3. Set your domain (FQDN)

Open **`nginx/default.conf`** and replace the domain in **both** server blocks:

```nginx
server {
    listen 443 ssl;
    server_name kuma.your-domain.com;    # ← change this
    ...
}

server {
    listen 80;
    server_name kuma.your-domain.com;    # ← change this
    ...
}
```

### 4. Place SSL certificates

Copy your certificate files into `nginx/certs/`:

```bash
cp /path/to/your/fullchain.pem nginx/certs/tls.crt
cp /path/to/your/privkey.pem   nginx/certs/tls.key
```

> Don't have a certificate yet? See [Step 3 — Get a Free SSL Certificate](#step-3--get-a-free-ssl-certificate) below.

---

## Step 3 — Get a Free SSL Certificate

Use [Certbot](https://certbot.eff.org/) with Let's Encrypt. Your domain's DNS must already point to this server before running these commands.

### 1. Install Certbot

```bash
# Ubuntu / Debian
sudo apt install -y certbot

# CentOS / RHEL
sudo yum install -y certbot
```

### 2. Issue the certificate

```bash
# Stop anything using port 80 first (if needed)
sudo certbot certonly --standalone -d kuma.your-domain.com
```

### 3. Copy certificates to the project

```bash
cp /etc/letsencrypt/live/kuma.your-domain.com/fullchain.pem nginx/certs/tls.crt
cp /etc/letsencrypt/live/kuma.your-domain.com/privkey.pem   nginx/certs/tls.key
```

> Certificates expire every 90 days. Set up auto-renewal:
> ```bash
> sudo systemctl enable --now certbot.timer
> # Verify the timer is active
> sudo systemctl status certbot.timer
> ```

---

## Step 4 — Deploy

### 1. Make the deploy script executable

```bash
chmod +x deploy.sh
```

### 2. Start all services

```bash
./deploy.sh up
```

This will pull all images, start MariaDB, wait for it to be healthy, then start Uptime Kuma, then Nginx.

### 3. Verify everything is running

```bash
./deploy.sh status
```

Expected output:
```
NAME         IMAGE                      STATUS
kuma-db      mariadb:11                 Up (healthy)
kuma-app     louislam/uptime-kuma:2     Up (healthy)
kuma-nginx   nginx:alpine               Up (healthy)
```

Uptime Kuma is now available at `https://kuma.your-domain.com`.

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

After changing passwords on a **fresh install** (no existing volume), re-run `./deploy.sh up`.

If the **database volume already exists**, update the password inside MariaDB too:

```bash
docker exec -it kuma-db mariadb -u root -p
ALTER USER 'kuma'@'%' IDENTIFIED BY 'your_new_password';
FLUSH PRIVILEGES;
EXIT;
```

### Password mismatch — reset the database volume

If you see `Access denied` and want to start fresh (no existing data to keep):

```bash
./deploy.sh down
docker volume rm db-data
./deploy.sh up
```

### Change the Uptime Kuma version

File: `docker-compose.yml`

```yaml
kuma-app:
  image: louislam/uptime-kuma:2.2.0   # pin to a specific version
```

### Change the MariaDB version

File: `docker-compose.yml`

```yaml
kuma-db:
  image: mariadb:10.11   # e.g. 10.11 for LTS
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

## Data & Backups

Persistent data is stored in Docker named volumes:

| Volume | Contents |
|---|---|
| `db-data` | MariaDB database files |
| `kuma-data` | Uptime Kuma config and monitor data |

### Backup

**1. Backup the database**
```bash
docker exec kuma-db mariadb-dump \
  -u root -p${MARIADB_ROOT_PASSWORD} uptimekuma \
  > backup_$(date +%F).sql
```

**2. Backup Uptime Kuma data**
```bash
docker run --rm \
  -v kuma-data:/data \
  -v $(pwd):/backup \
  alpine tar czf /backup/kuma-data_$(date +%F).tar.gz /data
```

### Restore

**1. Restore the database**
```bash
docker exec -i kuma-db mariadb \
  -u root -p${MARIADB_ROOT_PASSWORD} uptimekuma \
  < backup_2026-01-01.sql
```

**2. Restore Uptime Kuma data**
```bash
docker run --rm \
  -v kuma-data:/data \
  -v $(pwd):/backup \
  alpine tar xzf /backup/kuma-data_2026-01-01.tar.gz -C /
```

---

## Troubleshooting

### `Access denied for user 'kuma'`

The DB password in `.env` doesn't match what's stored in the volume (common after changing `.env` on an existing install).

**Fix — reset the volume (no existing data):**
```bash
./deploy.sh down
docker volume rm db-data
./deploy.sh up
```

**Fix — update password in running DB (keep existing data):**
```bash
docker exec -it kuma-db mariadb -u root -p
ALTER USER 'kuma'@'%' IDENTIFIED BY 'your_new_password';
FLUSH PRIVILEGES;
EXIT;
```

### `host not found in upstream "kuma-app"`

Nginx started before `kuma-app` was ready. If it still happens after `./deploy.sh up`:

```bash
docker restart kuma-nginx
```

### Uptime Kuma cannot connect to database

**1. Check DB is healthy**
```bash
./deploy.sh status
./deploy.sh logs kuma-db
```

**2. Verify credentials match in `.env`**
```bash
grep PASSWORD .env
```

**3. Test connection manually**
```bash
docker exec -it kuma-db mariadb -u kuma -p uptimekuma
```

### View logs

```bash
./deploy.sh logs             # all services
./deploy.sh logs kuma-db     # database only
./deploy.sh logs kuma-app    # Uptime Kuma only
./deploy.sh logs kuma-nginx  # Nginx only
```

### Reset everything (destructive)

```bash
./deploy.sh destroy   # removes containers AND volumes — all data lost
./deploy.sh up
```