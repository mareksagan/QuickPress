#!/bin/sh
set -e

# =============================================================================
# ClassicPress Alpine Linux Installer - VM Edition
# End-to-end automated installer for Alpine Linux VMs using OpenRC
# =============================================================================

# Configuration
DB_NAME="classicpress"
DB_USER="cpuser"
DB_PASS=""
WEB_ROOT="/var/www/classicpress"
PHP_VERSION="83"
CREDENTIALS_FILE="/root/classicpress-login.txt"
LOG_FILE="/var/log/classicpress-install.log"

# =============================================================================
# Helper Functions
# =============================================================================

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

error_exit() {
    echo "ERROR: $1" | tee -a "$LOG_FILE"
    exit 1
}

success() {
    echo "[OK] $1"
}

info() {
    echo "[*] $1"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error_exit "This script must be run as root"
    fi
    success "Running as root"
}

wait_for_port() {
    local port=$1
    local max_attempts=${2:-30}
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if nc -z 127.0.0.1 "$port" 2>/dev/null; then
            return 0
        fi
        sleep 1
        attempt=$((attempt + 1))
    done
    return 1
}

# =============================================================================
# Main Installation
# =============================================================================

echo ""
echo "=========================================="
echo "ClassicPress Alpine Linux Installer"
echo "=========================================="
echo ""

# Initialize log
touch "$LOG_FILE"
log "Starting ClassicPress installation"

# Check if running as root
check_root

# Check if Alpine Linux
if [ ! -f /etc/alpine-release ]; then
    error_exit "This script is designed for Alpine Linux only"
fi
success "Alpine Linux detected: $(cat /etc/alpine-release)"

# =============================================================================
# STEP 1: Install Packages
# =============================================================================
info "Step 1/6: Installing packages..."

# Update package index
apk update >> "$LOG_FILE" 2>&1

# Install all required packages
apk add --no-cache \
    nginx \
    "php${PHP_VERSION}" \
    "php${PHP_VERSION}-fpm" \
    "php${PHP_VERSION}-mysqli" \
    "php${PHP_VERSION}-gd" \
    "php${PHP_VERSION}-curl" \
    "php${PHP_VERSION}-mbstring" \
    "php${PHP_VERSION}-xml" \
    "php${PHP_VERSION}-zip" \
    "php${PHP_VERSION}-opcache" \
    "php${PHP_VERSION}-session" \
    "php${PHP_VERSION}-ctype" \
    "php${PHP_VERSION}-json" \
    "php${PHP_VERSION}-tokenizer" \
    "php${PHP_VERSION}-simplexml" \
    "php${PHP_VERSION}-dom" \
    "php${PHP_VERSION}-fileinfo" \
    "php${PHP_VERSION}-openssl" \
    mariadb \
    mariadb-client \
    curl \
    unzip \
    openssl \
    iproute2 \
    netcat-openbsd \
    >> "$LOG_FILE" 2>&1

success "Packages installed"

# Generate database password now that openssl is available
if [ -z "$DB_PASS" ]; then
    DB_PASS="cp$(openssl rand -hex 16)"
fi

# =============================================================================
# STEP 2: Configure and Start MariaDB
# =============================================================================
info "Step 2/6: Configuring MariaDB..."

# Create MariaDB directories
mkdir -p /run/mysqld
chown mysql:mysql /run/mysqld

# Configure MariaDB for TCP networking
cat > /etc/my.cnf.d/mariadb-server.cnf << 'EOF'
[mysqld]
bind-address = 127.0.0.1
port = 3306
skip-networking = 0
EOF

# Initialize MariaDB if needed
if [ ! -d /var/lib/mysql/mysql ]; then
    info "Initializing MariaDB data directory..."
    mysql_install_db --user=mysql --datadir=/var/lib/mysql --rpm >> "$LOG_FILE" 2>&1
fi

# Enable MariaDB
rc-update add mariadb default >> "$LOG_FILE" 2>&1

# Clean up any stale state from mysql_install_db
pkill -9 mysqld 2>/dev/null || true
pkill -9 mariadb 2>/dev/null || true
rm -f /var/lib/mysql/*.pid /run/mysqld/mysqld.sock /run/openrc/starting/mariadb /run/openrc/started/mariadb 2>/dev/null || true
sleep 2

# Start MariaDB
service mariadb start >> "$LOG_FILE" 2>&1 || {
    # If service start fails, try direct start
    /usr/bin/mysqld_safe --datadir=/var/lib/mysql &
    sleep 5
}

# Wait for MariaDB to be ready
info "Waiting for MariaDB to start..."
for i in $(seq 1 30); do
    if mariadb-admin ping -h 127.0.0.1 --silent 2>/dev/null; then
        success "MariaDB is running"
        break
    fi
    sleep 2
done

# Check if MariaDB is actually responding
if ! mariadb-admin ping -h 127.0.0.1 --silent 2>/dev/null; then
    error_exit "MariaDB failed to start"
fi

# Create database and user
mariadb -u root << EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${DB_USER}'@'localhost';
DROP USER IF EXISTS '${DB_USER}'@'127.0.0.1';
CREATE USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
EOF

# Verify database exists
if ! mariadb -u root -e "USE ${DB_NAME};" 2>/dev/null; then
    error_exit "Failed to create database"
fi

success "MariaDB configured and database created"

# =============================================================================
# STEP 3: Download ClassicPress
# =============================================================================
info "Step 3/6: Downloading ClassicPress..."

# Clean and create web root
rm -rf ${WEB_ROOT}
mkdir -p ${WEB_ROOT}
cd /tmp

# Download ClassicPress
CP_VERSION="2.6.0"
CP_URL="https://github.com/ClassicPress/ClassicPress-release/archive/refs/tags/${CP_VERSION}.zip"

curl -fsSL "$CP_URL" -o cp.zip >> "$LOG_FILE" 2>&1 || error_exit "Failed to download ClassicPress"
unzip -q cp.zip || error_exit "Failed to extract ClassicPress"
mv "ClassicPress-release-${CP_VERSION}"/* ${WEB_ROOT}/ || error_exit "Failed to move ClassicPress files"
rm -rf "ClassicPress-release-${CP_VERSION}" cp.zip

# Verify download
if [ ! -f "${WEB_ROOT}/index.php" ]; then
    error_exit "ClassicPress download appears incomplete"
fi

success "ClassicPress ${CP_VERSION} downloaded"

# =============================================================================
# STEP 4: Configure PHP-FPM
# =============================================================================
info "Step 4/6: Configuring PHP-FPM..."

# Configure PHP-FPM to use TCP and run as nginx
sed -i 's|^listen =.*|listen = 127.0.0.1:9000|' /etc/php${PHP_VERSION}/php-fpm.d/www.conf
sed -i 's/^user =.*/user = nginx/' /etc/php${PHP_VERSION}/php-fpm.d/www.conf
sed -i 's/^group =.*/group = nginx/' /etc/php${PHP_VERSION}/php-fpm.d/www.conf

# Enable PHP-FPM (but don't let it auto-start yet)
rc-update add "php-fpm${PHP_VERSION}" default >> "$LOG_FILE" 2>&1

# Clean up and start PHP-FPM
pkill -9 "php-fpm" 2>/dev/null || true
rm -f /run/openrc/starting/php-fpm${PHP_VERSION} /run/openrc/started/php-fpm${PHP_VERSION} 2>/dev/null || true
sleep 1

# Start PHP-FPM directly
/usr/sbin/php-fpm${PHP_VERSION} -F >> "$LOG_FILE" 2>&1 &
sleep 3

# Verify it's running
if ! pgrep -x php-fpm${PHP_VERSION} > /dev/null 2>&1; then
    # Try service start as fallback
    service "php-fpm${PHP_VERSION}" start >> "$LOG_FILE" 2>&1 || true
    sleep 3
fi

wait_for_port 9000 || error_exit "PHP-FPM did not open port 9000"

success "PHP-FPM configured and running"

# =============================================================================
# STEP 5: Create wp-config.php
# =============================================================================
info "Step 5/6: Creating wp-config.php..."

cd ${WEB_ROOT}

# Generate WordPress salts
SALT_AUTH_KEY=$(openssl rand -hex 32)
SALT_SECURE_AUTH_KEY=$(openssl rand -hex 32)
SALT_LOGGED_IN_KEY=$(openssl rand -hex 32)
SALT_NONCE_KEY=$(openssl rand -hex 32)
SALT_AUTH_SALT=$(openssl rand -hex 32)
SALT_SECURE_AUTH_SALT=$(openssl rand -hex 32)
SALT_LOGGED_IN_SALT=$(openssl rand -hex 32)
SALT_NONCE_SALT=$(openssl rand -hex 32)

# Create wp-config.php
cat > wp-config.php << EOF
<?php
/**
 * ClassicPress Configuration File
 * Generated by QuickPress Installer
 */

// Database settings
define('DB_NAME', '${DB_NAME}');
define('DB_USER', '${DB_USER}');
define('DB_PASSWORD', '${DB_PASS}');
define('DB_HOST', '127.0.0.1');
define('DB_CHARSET', 'utf8mb4');
define('DB_COLLATE', 'utf8mb4_unicode_ci');

// Authentication keys and salts
define('AUTH_KEY',         '${SALT_AUTH_KEY}');
define('SECURE_AUTH_KEY',  '${SALT_SECURE_AUTH_KEY}');
define('LOGGED_IN_KEY',    '${SALT_LOGGED_IN_KEY}');
define('NONCE_KEY',        '${SALT_NONCE_KEY}');
define('AUTH_SALT',        '${SALT_AUTH_SALT}');
define('SECURE_AUTH_SALT', '${SALT_SECURE_AUTH_SALT}');
define('LOGGED_IN_SALT',   '${SALT_LOGGED_IN_SALT}');
define('NONCE_SALT',       '${SALT_NONCE_SALT}');

// Table prefix
\$table_prefix = 'cp_';

// Debug mode (disable in production)
define('WP_DEBUG', false);

// Absolute path to the WordPress directory
if (!defined('ABSPATH')) {
    define('ABSPATH', __DIR__ . '/');
}

// Sets up ClassicPress vars and included files
require_once ABSPATH . 'wp-settings.php';
EOF

# Set ownership and permissions
chown -R nginx:nginx ${WEB_ROOT}
chmod 644 ${WEB_ROOT}/wp-config.php

success "wp-config.php created"

# =============================================================================
# STEP 6: Configure Nginx
# =============================================================================
info "Step 6/6: Configuring Nginx..."

# Create Nginx configuration
cat > /etc/nginx/http.d/classicpress.conf << 'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /var/www/classicpress;
    index index.php index.html;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1000;
    gzip_types text/plain text/css application/json application/javascript text/xml;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        try_files $uri =404;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
        
        # PHP-FPM timeout settings
        fastcgi_connect_timeout 60s;
        fastcgi_send_timeout 60s;
        fastcgi_read_timeout 60s;
    }

    # Deny access to hidden files
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Deny access to sensitive files
    location ~ /(wp-config\.php|wp-admin/install\.php)\. {
        deny all;
    }
}
EOF

# Remove default config if exists
rm -f /etc/nginx/http.d/default.conf

# Test Nginx configuration
nginx -t >> "$LOG_FILE" 2>&1 || error_exit "Nginx configuration test failed"

# Enable Nginx
rc-update add nginx default >> "$LOG_FILE" 2>&1

# Clean up and start Nginx
pkill -9 nginx 2>/dev/null || true
rm -f /run/openrc/starting/nginx /run/openrc/started/nginx 2>/dev/null || true
sleep 1

# Start nginx directly
/usr/sbin/nginx -g 'daemon off;' >> "$LOG_FILE" 2>&1 &
sleep 3

success "Nginx configured and running"

# =============================================================================
# Verification
# =============================================================================
info "Verifying installation..."

# Test PHP is working via Nginx
TEST_RESPONSE=$(wget -qO- --timeout=10 http://127.0.0.1/wp-admin/install.php 2>/dev/null || echo "FAILED")

if echo "$TEST_RESPONSE" | grep -q "ClassicPress"; then
    success "Web server responding correctly"
else
    error_exit "Web server test failed - check ${LOG_FILE}"
fi

# Test database connection via PHP
php${PHP_VERSION} -r "
require '${WEB_ROOT}/wp-config.php';
\$mysqli = new mysqli(DB_HOST, DB_USER, DB_PASSWORD, DB_NAME);
if (\$mysqli->connect_error) {
    exit(1);
}
exit(0);
" 2>/dev/null || error_exit "Database connection test failed"

success "Database connection verified"

# =============================================================================
# Get Server IP
# =============================================================================
IP=$(ip addr show 2>/dev/null | grep "inet " | grep -v "127.0.0.1" | head -1 | awk '{print $2}' | cut -d/ -f1)
if [ -z "$IP" ]; then
    IP=$(hostname -i 2>/dev/null | awk '{print $1}')
fi
if [ -z "$IP" ]; then
    IP="YOUR_SERVER_IP"
fi

# =============================================================================
# Save Credentials
# =============================================================================
cat > ${CREDENTIALS_FILE} << EOF
========================================
ClassicPress Installation Credentials
========================================
Generated: $(date)
Log File: ${LOG_FILE}

WEBSITE
-------
URL: http://${IP}/wp-admin/install.php
Local: http://127.0.0.1/wp-admin/install.php

DATABASE
--------
Name:     ${DB_NAME}
User:     ${DB_USER}
Password: ${DB_PASS}
Host:     127.0.0.1
Port:     3306

FILE LOCATIONS
--------------
Web Root:  ${WEB_ROOT}
Config:    ${WEB_ROOT}/wp-config.php
Nginx:     /etc/nginx/http.d/classicpress.conf
MariaDB:   /etc/my.cnf.d/mariadb-server.cnf

SERVICE COMMANDS
----------------
Restart Nginx:     service nginx restart
Restart PHP-FPM:   service php-fpm${PHP_VERSION} restart
Restart MariaDB:   service mariadb restart

Check Status:
  service nginx status
  service php-fpm${PHP_VERSION} status
  service mariadb status

View Logs:
  tail -f ${LOG_FILE}
  tail -f /var/log/nginx/error.log
========================================
EOF

chmod 600 ${CREDENTIALS_FILE}

# =============================================================================
# Final Output
# =============================================================================
echo ""
echo "=========================================="
echo "INSTALLATION COMPLETE!"
echo "=========================================="
echo ""
echo "Setup URL: http://${IP}/wp-admin/install.php"
echo ""
echo "Database Info:"
echo "   Name:     ${DB_NAME}"
echo "   User:     ${DB_USER}"
echo "   Password: ${DB_PASS}"
echo ""
echo "Credentials saved to: ${CREDENTIALS_FILE}"
echo ""
echo "Next Steps:"
echo "   1. Open http://${IP}/wp-admin/install.php in your browser"
echo "   2. Complete the ClassicPress setup wizard"
echo "   3. Configure your site title and admin user"
echo ""
echo "Service Management:"
echo "   service nginx restart    - Restart web server"
echo "   service php-fpm${PHP_VERSION} restart - Restart PHP"
echo "   service mariadb restart  - Restart database"
echo ""
echo "=========================================="

log "Installation completed successfully"
exit 0
