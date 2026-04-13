# n8n Stack - Installation Guide

Complete self-hosted stack with n8n, Supabase, Nginx Proxy Manager, and Cloudflare Tunnel.

## Features

- **n8n** - Workflow automation platform
- **Nginx Proxy Manager** - Easy SSL and reverse proxy management (optional)
- **Cloudflare Tunnel** - Secure tunnel without exposing ports for Local hosted (optional)
- **Portainer** - Docker container management UI (optional)

## Prerequisites

- **Docker Desktop** (macOS/Windows) or **Docker Engine** (Linux)
- **Git**
- **2GB+ RAM** recommended

### Install Docker

#### Linux
```bash
sudo systemctl enable ssh
```
SSH will start automatically every time the system boots

```bash
sudo apt update && sudo apt upgrade -y
curl -fsSL https://get.docker.com | sudo sh
docker --version
sudo usermod -aG docker $USER
newgrp docker
```

**Note**

The Docker service starts automatically after installation. To verify that Docker is running, use:
```bash
sudo systemctl status docker
```
Some systems may have this behavior disabled and will require a manual start:
```bash
sudo systemctl start docker
```

Verify that the installation is successful by running the hello-world image:
```bash
sudo docker run hello-world
```
This command downloads a test image and runs it in a container. When the container runs, it prints a confirmation message and exits.

#### macOS
Download from: https://docs.docker.com/desktop/install/mac-install/

Or via Homebrew:
```bash
brew install --cask docker
```

#### Windows
Download from: https://docs.docker.com/desktop/install/windows-install/

Make sure WSL2 backend is enabled.

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/t0ny-m/n8n-pg-stack.git
cd n8n-pg-stack
```

### 2. Setup environment files

```
cp n8n/.env.example n8n/.env
cp proxy/cloudflared/.env.example proxy/cloudflared/.env
```

#### n8n configuration

```bash
cd n8n
nano .env  # or use your preferred editor
```

Edit `n8n/.env` and set:
- `N8N_HOST`, `DOMAIN_NAME`, `WEBHOOK_URL` - your domain/subdomain
- `N8N_ENCRYPTION_KEY` - generate with: `openssl rand -hex 16`
- `DB_POSTGRESDB_PASSWORD` - generate with: `openssl rand -hex 32`


#### Nginx Proxy Manager (optional)

```bash
cd proxy/npm
```
- No environment variables required for basic setup

#### Cloudflared Tunnel (optional)

```bash
cd proxy/cloudflared
nano .env  # or use your preferred editor
```

Set `CLOUDFLARE_TUNNEL_TOKEN` from Cloudflare Zero Trust Dashboard.
1. Go to https://one.dash.cloudflare.com/
2. Navigate to Networks → Tunnels
3. Create a tunnel and copy the token

**Important:** Keep all generated keys secure and never commit them to git!

### 3. Start the stack

```bash
cd n8n-pg-stack  # Go to project root
chmod +x start-stack.sh
./start-stack.sh
```

**The script will automatically:**
1. Check if Docker is running
2. Create network if needed
3. Let you choose which services to start
4. Start services in correct order

#### Interactive menu (if whiptail/dialog available):
```
┌─────────── Stack Startup ───────────┐
│ Select services (Space=select):     │
│                                     │
│ [X] n8n                             │
│ [X] Nginx Proxy Manager             │
│ [ ] Cloudflared Tunnel              │
│ [ ] Portainer                       │
│                                     │
│         <OK>        <Cancel>        │
└─────────────────────────────────────┘
```

#### Simple mode (without whiptail):
```
Start n8n? [y/N]: y
Start Nginx Proxy Manager? [y/N]: y
Start Cloudflared Tunnel? [y/N]: n
Start Portainer? [y/N]: n
```

### 4. Access services

After startup, access:
- **n8n**: http://localhost:5678
- **Nginx Proxy Manager**: http://localhost:81

## Usage

### Start services

```bash
./start-stack.sh
```

Interactive menu will let you choose which services to start.

### Stop services

```bash
# Stop n8n
cd n8n && docker compose down

# Stop NPM
cd proxy/npm && docker compose down
```

### View logs

```bash
# n8n logs
docker logs n8n -f
```

### Restart a service

```bash
cd n8n
docker compose restart
```

### Update services

```bash
# Pull latest images
cd n8n
docker compose pull

# Recreate containers
docker compose up -d
```

## Backup & Restore

The repository includes automated scripts to easily backup and restore your stack.

For detailed instructions, please see the documentation:
- [Backup Instructions & Migration Guide](docs/BACKUP_INSTRUCTIONS.md)
- [Restore Instructions](docs/RESTORE_INSTRUCTIONS.md)

### Automated Backup

To create a backup of your selected services:
```bash
sudo ./scripts/backup/backup-stack.sh
```
Follow the interactive prompts to select what to backup and optionally create a single `.tar.gz` archive.

### Automated Restore

To restore your stack from a backup on a new instance or over existing data:
```bash
sudo ./scripts/restore/restore-stack.sh
```
The script will automatically find the latest backup in the `backups/` directory and guide you through the process.

## Troubleshooting

### Docker not running

**Linux:**
```bash
sudo systemctl start docker
sudo systemctl enable docker
```

**macOS/Windows:**
- Make sure Docker Desktop application is running
- Look for Docker icon in system tray/menu bar
- Restart Docker Desktop if needed

### Port conflicts

If ports 5678, 8000, 80, 443, or 81 are already in use, edit the respective `docker-compose.yml` files to change port mappings.

### n8n can't connect to database

Make sure:
1. n8n-db is running: `docker ps | grep n8n-db`
2. Database is healthy: `docker inspect n8n-db --format='{{.State.Health.Status}}'`
3. Check `n8n/.env` has correct database credentials (POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB)
4. Database volume exists: `docker volume ls | grep db_storage`

### Network issues

Recreate network:
```bash
docker network rm n8n-stack-network
docker network create n8n-stack-network
```
### Container keeps restarting

**Check logs:**
```bash
docker logs <container-name> --tail 100
```

**Common causes:**
- Missing or incorrect `.env` configuration
- Port already in use
- Insufficient memory (increase Docker memory limit)
- Database not ready (n8n waiting for n8n-db)

### Out of memory (t3.micro/small instances)

**Enable swap:**
```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# Make permanent
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
```

**Reduce memory limits in docker-compose.yml:**
```yaml
deploy:
  resources:
    limits:
      memory: 512M  # Reduce from 1024M
```

**Run minimal services:**
- Start only n8n

## Architecture

```
                    Internet
                        │
          ┌─────────────┴─────────────┐
          │    NPM/Cloudflare Tunnel  │ (optional)
          │         :80/:443          │
          └─────────────┬─────────────┘
                        │
    ┌───────────────────┼───────────────────┐
    │                                       │
┌───┴───┐                              ┌────┴────┐
│  n8n  │ :5678                        │Portainer│
│       │                              │(optional)│
│┌─────┐│                              └─────────┘
││n8n- ││
││db   ││
│└─────┘│
└───────┘
INDEPENDENT         INDEPENDENT

        All on: n8n-stack-network
```

### Component Relationships

- **n8n** uses its own **n8n-db** (PostgreSQL 16)
- **n8n-db** is initialized automatically using `init-data.sh`
- **NPM** and **Cloudflared** are optional for reverse proxy/SSL
- All services communicate via `n8n-stack-network` Docker network

## Project Structure

```
n8n-pg-stack/
├── start-stack.sh              # Main startup script
├── README.md
├── n8n/
│   ├── docker-compose.yml
│   ├── .env.example
│   ├── init-data.sh            # DB initialization
│   ├── files/
│   └── backup/
├── proxy/
│   ├── npm/
│   │   ├── docker-compose.yml
│   │   └── .env.example
│   └── cloudflared/
│       ├── docker-compose.yml
│       └── .env.example
├── portainer/
│   ├── docker-compose.yml
│   └── .env.example
├── scripts/
│   ├── backup/
│   │   └── backup-stack.sh     # Backup script
│   └── restore/
│       └── restore-stack.sh    # Restore script
└── docs/
    ├── BACKUP_INSTRUCTIONS.md
    └── RESTORE_INSTRUCTIONS.md
```

## Resources

- [n8n Documentation](https://docs.n8n.io/)
- [Nginx Proxy Manager](https://nginxproxymanager.com/)
- [Cloudflare Tunnels](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/)

## Security Best Practices

1. **Change default passwords** immediately after first login
2. **Use strong encryption keys** (generated with `openssl rand`)
3. **Never commit `.env` files** to git (they're in `.gitignore`)
4. **Enable firewall** if exposing ports directly:
```bash
# Linux (ufw)
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```
5. **Use Cloudflare Tunnel** instead of exposing ports when possible
6. **Regular backups** of databases and n8n workflows
7. **Update regularly** by pulling latest Docker images

## License

MIT

## Support

For issues and questions:
- Open an issue on GitHub
- Check [n8n community forum](https://community.n8n.io/)
