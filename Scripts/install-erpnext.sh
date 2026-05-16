#!/bin/bash
set -euo pipefail

LOG=/var/log/erpnext-install.log
exec > >(tee -a "$LOG") 2>&1

echo "================================================================"
echo "  ERPNext Installation Script"
echo "  Generated: 2026-05-16 12:01:53"
echo "================================================================"

# Variables (injected by deployment script)
ADMIN_USER='jtadmin'
MARIADB_ROOT_PW='JfpZ2gHGvFtHEokneW#F7gEeZFRy'
ERPNEXT_ADMIN_PW='!NC9vnNp5Md3_AhouwdmN3*D'
PUBLIC_IP='20.25.28.24'

echo "[1/10] Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
sudo -E apt-get update
sudo -E apt-get upgrade -y

echo "[2/10] Installing prerequisites..."
sudo -E apt-get install -y git python3-dev python3-pip python3-venv python3-setuptools \
    redis-server mariadb-server mariadb-client libmariadb-dev \
    nginx supervisor curl wget xvfb libfontconfig xfonts-75dpi xfonts-base \
    software-properties-common build-essential

echo "[3/10] Securing MariaDB..."
sudo mysql <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MARIADB_ROOT_PW}';
EOF
sudo mysql -u root -p"${MARIADB_ROOT_PW}" <<EOF
DELETE FROM mysql.user WHERE User = '';
DELETE FROM mysql.user WHERE User = 'root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
EOF

echo "[4/10] Tuning MariaDB for ERPNext..."
sudo tee /etc/mysql/mariadb.conf.d/60-erpnext.cnf > /dev/null <<'EOF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
max_allowed_packet = 256M
innodb_buffer_pool_size = 2G
innodb_log_file_size = 256M
innodb_read_io_threads = 4
innodb_write_io_threads = 4

[mysql]
default-character-set = utf8mb4
EOF
sudo systemctl restart mariadb

echo "[5/10] Installing Node.js 20 LTS and Yarn..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo -E apt-get install -y nodejs
sudo npm install -g yarn

echo "[6/10] Installing wkhtmltopdf (Ubuntu 24.04 noble build)..."
WKHTMLTOPDF_DEB=wkhtmltox_0.12.6.1-3.jammy_amd64.deb
cd /tmp
wget -q "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/${WKHTMLTOPDF_DEB}"
sudo apt-get install -y "./${WKHTMLTOPDF_DEB}"
rm -f "${WKHTMLTOPDF_DEB}"

echo "[7/10] Installing Frappe Bench..."
sudo pip3 install --break-system-packages frappe-bench

echo "[8/10] Initializing Frappe Bench and pulling apps..."
sudo -u "${ADMIN_USER}" bash -c "cd /home/${ADMIN_USER} && bench init --frappe-branch version-15 frappe-bench"
sudo -u "${ADMIN_USER}" bash -c "cd /home/${ADMIN_USER}/frappe-bench && bench get-app erpnext --branch version-15"
sudo -u "${ADMIN_USER}" bash -c "cd /home/${ADMIN_USER}/frappe-bench && bench get-app hrms --branch version-15"

# CRITICAL: Frappe needs its private Redis instances running before
# "bench new-site" can succeed. Frappe v15 uses two by default:
#   redis_queue.conf (default port 11000)
#   redis_cache.conf (default port 13000)
# Older versions also had redis_socketio.conf on port 12000, dropped in v15.
# Port assignments and config files are subject to change between Frappe
# versions, so we discover them dynamically from the generated configs
# rather than hardcoding.
echo "[8a/10] Starting Frappe-managed Redis instances..."

# Embedded helper script (avoids PowerShell-to-bash quoting hell for the complex
# control flow below). Written as a heredoc so PowerShell never tries to parse
# the bash variables/operators.
cat > /tmp/start-redis-instances.sh <<'REDIS_HELPER_EOF'
#!/bin/bash
set -e
BENCH_DIR="$1"
ADMIN_USER="$2"
OUT_PORTS_FILE="$3"

cd "$BENCH_DIR"
CONFIGS=$(ls config/redis_*.conf 2>/dev/null)
if [ -z "$CONFIGS" ]; then
    echo "  ERROR: No redis_*.conf files found" >&2
    exit 1
fi
echo "  Found Redis configs:"
echo "$CONFIGS" | sed "s/^/    /"

> "$OUT_PORTS_FILE"
for conf in $CONFIGS; do
    conf_basename=$(basename "$conf" .conf)
    port=$(grep -E "^port " "$conf" | awk "{print \$2}" | head -1)
    if [ -z "$port" ]; then
        echo "  WARNING: no port directive in $conf, skipping" >&2
        continue
    fi
    echo "  Starting $conf_basename on port $port..."
    sudo -u "$ADMIN_USER" bash -c "cd $BENCH_DIR && nohup redis-server $conf >/tmp/$conf_basename.log 2>&1 &"
    echo "$port" >> "$OUT_PORTS_FILE"
done

echo "  Waiting for Redis instances to be ready..."
while read -r port; do
    for i in $(seq 1 30); do
        if redis-cli -p "$port" ping 2>/dev/null | grep -q PONG; then
            echo "    Redis on port $port is up."
            break
        fi
        sleep 1
        if [ "$i" -eq 30 ]; then
            echo "    ERROR: Redis on port $port did not start within 30s." >&2
            cat /tmp/redis_*.log >&2 2>/dev/null || true
            exit 1
        fi
    done
done < "$OUT_PORTS_FILE"
REDIS_HELPER_EOF

chmod +x /tmp/start-redis-instances.sh
/tmp/start-redis-instances.sh /home/${ADMIN_USER}/frappe-bench ${ADMIN_USER} /tmp/redis-ports.list
REDIS_PORTS=$(tr "\n" " " < /tmp/redis-ports.list)
echo "[8b/10] Redis startup complete. Ports: $REDIS_PORTS"

echo "[9/10] Creating site and installing apps..."
sudo -u "${ADMIN_USER}" bash <<NEWSITE_EOF
cd /home/${ADMIN_USER}/frappe-bench
bench new-site jtcustomtrailers.local --mariadb-root-password "${MARIADB_ROOT_PW}" --admin-password "${ERPNEXT_ADMIN_PW}"
bench --site jtcustomtrailers.local install-app erpnext
bench --site jtcustomtrailers.local install-app hrms
NEWSITE_EOF

# Stop the standalone Redis instances we started - they will be replaced
# by supervisor-managed ones in the next step.
echo "[9a/10] Stopping standalone Redis (will be replaced by supervisor)..."
for port in $REDIS_PORTS; do
    redis-cli -p $port shutdown nosave 2>/dev/null || true
done

echo "[10/10] Configuring production (Nginx + Supervisor)..."
sudo bash -c "cd /home/jtadmin/frappe-bench && bench setup production jtadmin --yes"
sudo bash -c "cd /home/jtadmin/frappe-bench && bench setup nginx --yes"
sudo supervisorctl reload

# Sentinel: this exact line is parsed by the deploy script to confirm real success.
# If the install bombed earlier, set -euo pipefail will have exited before reaching here.
echo "ERPNEXT_INSTALL_STATUS=SUCCESS"

echo ""
echo "================================================================"
echo "  ERPNext Installation Complete"
echo "================================================================"
echo "  URL:      http://${PUBLIC_IP}"
echo "  Username: Administrator"
echo "  (Password stored in Key Vault or local JSON by deployer)"
echo "================================================================"