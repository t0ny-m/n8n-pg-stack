# Backup and Migration Guide

This guide explains how to back up your n8n-stack and migrate it to a new instance.

## 1. Quick Backup

The easiest way to backup is using the included script.

```bash
./scripts/backup/backup-stack.sh
```

Run the backup script as your normal user whenever possible.

- On macOS with Docker Desktop or OrbStack, do not use `sudo` for backup/restore unless you have a very specific reason.
- Running restore as `root` can leave bind-mounted directories such as `proxy/npm/data` and `proxy/npm/letsencrypt` owned by `root`, which breaks Nginx Proxy Manager on macOS.
- On Linux, if your user is not in the `docker` group, either fix Docker permissions first or be aware that `sudo` changes file ownership semantics.

- Select the services you want to backup.
- Choose whether to stop services (recommended for database consistency).
- The script will create individual backup folders in `backups/<service>/`.
- At the end, you can choose to create a single `.tar.gz` archive of all created backups.

## 2. Manual Backup

If you prefer to backup manually, here is what you need to save for each service.

### n8n
- **Location**: `n8n/`
- **Files**: `.env`
- **Directories**: `files/`
- **Data Volume**: `n8n_data` (Named Volume)
  - To backup: `docker run --rm -v n8n_data:/volume -v $(pwd):/backup alpine tar -czf /backup/n8n_data.tar.gz -C /volume .`
- **Logical Backup**: The script automatically creates `n8n_db_dump.sql` by running `pg_dump` against the `n8n-db` container before stopping services.

### Nginx Proxy Manager (NPM)
- **Location**: `proxy/npm/`
- **Directories**: `data/`, `letsencrypt/`
- **Important**: Backup and restore must preserve symlinks inside `letsencrypt/live/` and the matching private keys inside `letsencrypt/archive/`.
- **Safe manual backup**:
  ```bash
  cd proxy/npm
  docker compose stop npm
  tar -czpf npm_backup_$(date +%F_%H-%M).tar.gz data letsencrypt
  docker compose start npm
  ```

### Cloudflared
- **Location**: `proxy/cloudflared/`
- **Files**: `.env` (Contains Tunnel Token)

### Portainer
- **Location**: `portainer/`
- **Data Volume**: `portainer_data` (Named Volume)
  - To backup: `docker run --rm -v portainer_data:/volume -v $(pwd):/backup alpine tar -czf /backup/portainer_data.tar.gz -C /volume .`

---

## 3. Migration Guide

Follow these steps to move your stack to a new server.

### Step 1: Prepare New Server
1. Install Docker and Docker Compose.
2. Clone this repository to the new server.
   ```bash
   git clone https://github.com/t0ny-m/n8n-pg-stack.git
   cd n8n-pg-stack
   ```

### Step 2: Transfer Backup
Copy your backup archive (`n8n_stack_backup_YYYYMMDD_....tar.gz`) to the new server.

### Step 3: Restore Data
1. Extract the backup archive.
   ```bash
   mkdir temp_restore
   tar -xzf n8n_stack_backup_....tar.gz -C temp_restore
   ```

2. **Restore n8n**
   - Copy `.env` and `files/` to `n8n/`.
   - Restore volume:
     ```bash
     docker volume create n8n_data
     docker run --rm -v n8n_data:/volume -v $(pwd)/temp_restore/n8n:/backup alpine tar -xzf /backup/n8n_data.tar.gz -C /volume
     ```

4. **Restore NPM**
   - Stop `npm` first.
   - Restore `data` and `letsencrypt` with a method that preserves symlinks:
     ```bash
     cd proxy/npm
     docker compose down
     rm -rf data letsencrypt
     mkdir -p data letsencrypt
     tar -cpf - -C ../../temp_restore/npm/npm_backup_.../data . | tar -xpf - -C data
     tar -cpf - -C ../../temp_restore/npm/npm_backup_.../letsencrypt . | tar -xpf - -C letsencrypt
     ```
   - On macOS, make sure the restored directories are owned by your normal user:
     ```bash
     chown -R "$(id -un):$(id -gn)" data letsencrypt
     chmod -R u+rwX data letsencrypt
     xattr -rc data letsencrypt 2>/dev/null || true
     chmod -RN data letsencrypt 2>/dev/null || true
     ```

5. **Restore Cloudflared**
   - Copy `.env` to `proxy/cloudflared/`.

6. **Restore Portainer**
   - Restore volume:
     ```bash
     docker volume create portainer_data
     docker run --rm -v portainer_data:/volume -v $(pwd)/temp_restore/portainer:/backup alpine tar -xzf /backup/portainer_data.tar.gz -C /volume
     ```

### Step 4: Start Stack
Run the start script to launch your services.

```bash
./start-stack.sh
```
