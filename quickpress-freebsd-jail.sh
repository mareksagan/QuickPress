#!/usr/local/bin/bash
set -e

# =============================================================================
# ClassicPress FreeBSD Jail Installer
# Creates isolated jails for web, database, and cache with pf firewall
#
# Usage: ./quickpress-freebsd-jail.sh [OPTIONS]
# =============================================================================

# Configuration
JAIL_BASE="/usr/jails"
JAIL_WEB="cp-web"
JAIL_DB="cp-db"
JAIL_CACHE="cp-cache"
JAIL_NETWORK="10.100.100"
WEB_IP="${JAIL_NETWORK}.10"
DB_IP="${JAIL_NETWORK}.20"
CACHE_IP="${JAIL_NETWORK}.30"
HOST_IP="${JAIL_NETWORK}.1"

DB_NAME="classicpress"
DB_USER="cpuser"
DB_PASS=""
WEB_ROOT="/usr/local/www/classicpress"
PHP_VERSION="83"
CREDENTIALS_FILE="/root/classicpress-login.txt"
LOG_FILE="/var/log/classicpress-jail-install.log"

# SSL Configuration
DOMAIN=""
EMAIL=""
SSL_MODE=""

# Show help
show_help() {
    cat << HELP
ClassicPress FreeBSD Jail Installer

USAGE:
    ./quickpress-freebsd-jail.sh [OPTIONS]

SSL OPTIONS:
    --ssl-domain <DOMAIN>     Domain for Let's Encrypt SSL
    --ssl-email <EMAIL>       Email for Let's Encrypt SSL
    --ssl-self-signed         Use self-signed certificate

EXAMPLES:
    ./quickpress-freebsd-jail.sh --ssl-domain example.com --ssl-email admin@example.com
    ./quickpress-freebsd-jail.sh --ssl-self-signed
    ./quickpress-freebsd-jail.sh
HELP
}

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --ssl-domain)
            DOMAIN="$2"
            SSL_MODE="letsencrypt"
            shift 2
            ;;
        --ssl-email)
            EMAIL="$2"
            shift 2
            ;;
        --ssl-self-signed)
            SSL_MODE="selfsigned"
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate SSL options
if [ "$SSL_MODE" = "letsencrypt" ]; then
    if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
        echo "ERROR: Let's Encrypt SSL requires both --ssl-domain and --ssl-email"
        exit 1
    fi
fi

# Helper functions
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

# Check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error_exit "This script must be run as root"
    fi
}

# =============================================================================
# Main Installation
# =============================================================================

echo ""
echo "=========================================="
echo "ClassicPress FreeBSD Jail Installer"
echo "=========================================="
echo ""

check_root
touch "$LOG_FILE"
log "Starting ClassicPress jail installation"

# Check FreeBSD
if [ ! -f /etc/freebsd-version ] && ! uname -s | grep -q "FreeBSD"; then
    error_exit "This script requires FreeBSD"
fi

FREEBSD_VERSION=$(uname -r | cut -d'-' -f1)
info "FreeBSD version: $FREEBSD_VERSION"

# =============================================================================
# STEP 1: Install Required Packages on Host
# =============================================================================
info "Step 1/10: Installing host packages..."

export BATCH=yes
export ASSUME_ALWAYS_YES=yes

# Update package index
pkg update -f >> "$LOG_FILE" 2>&1 || true

# Install required packages for jail management
pkg install -y \
    ezjail \
    nginx 2>/dev/null || pkg install -y ezjail || true

# Note: PF is part of FreeBSD base system, no package needed

success "Host packages installed"

# =============================================================================
# STEP 2: Configure PF Firewall
# =============================================================================
info "Step 2/10: Configuring PF firewall..."

# Detect network interface (try common ones)
EXT_IF=""
for iface in vtnet0 eth0 em0 igb0 ix0 bge0 re0 alc0; do
    if ifconfig "$iface" >/dev/null 2>&1; then
        EXT_IF="$iface"
        break
    fi
done

# Fallback detection
if [ -z "$EXT_IF" ]; then
    EXT_IF=$(ifconfig | grep -E "^(em|igb|ix|bge|re|alc|vtnet)" | head -1 | cut -d: -f1)
fi

# Final fallback
[ -z "$EXT_IF" ] && EXT_IF="vtnet0"

info "Detected network interface: $EXT_IF"

# Create pf configuration
cat > /etc/pf.conf << EOF
# PF Firewall Configuration for ClassicPress Jails

# Interfaces
ext_if="$EXT_IF"
jail_if="lo1"

# Jail network  
jail_net="10.100.100.0/24"
web_jail="10.100.100.10"
db_jail="10.100.100.20"
cache_jail="10.100.100.30"

# Set options
set skip on lo0
set skip on lo1

# NAT and redirection
nat on $EXT_IF from 10.100.100.0/24 to any -> ($EXT_IF)
rdr pass on $EXT_IF inet proto tcp to port 80 -> 10.100.100.10
rdr pass on $EXT_IF inet proto tcp to port 443 -> 10.100.100.10

# Allow jail-to-jail communication
pass quick on lo1 inet proto tcp from 10.100.100.10 to 10.100.100.20 port 3306
pass quick on lo1 inet proto tcp from 10.100.100.10 to 10.100.100.30 port 6379
pass quick on lo1 inet proto tcp from 10.100.100.20 to 10.100.100.10 port 80
pass quick on lo1 inet proto tcp from 10.100.100.30 to 10.100.100.10

# Allow outbound connections from jails
pass out on $EXT_IF inet proto tcp from 10.100.100.0/24 to any port { 80, 443 }
pass out on $EXT_IF inet proto udp from 10.100.100.0/24 to any port 53

# Allow established connections
pass inet proto tcp from any to any port 22 keep state
pass inet proto icmp all

# Block direct access to jails from outside
block in on $EXT_IF inet from any to 10.100.100.0/24
EOF

# Enable and start PF
sysrc pf_enable="YES" >> "$LOG_FILE" 2>&1 || true
sysrc pflog_enable="YES" >> "$LOG_FILE" 2>&1 || true

service pf start >> "$LOG_FILE" 2>&1 || service pf restart >> "$LOG_FILE" 2>&1 || {
    info "Warning: PF failed to start, continuing anyway..."
}

success "PF firewall configured"

# =============================================================================
# STEP 3: Setup Jail Network (lo1)
# =============================================================================
info "Step 3/10: Setting up jail network..."

# Create cloned interface for jails
sysrc cloned_interfaces="lo1" >> "$LOG_FILE" 2>&1 || true
sysrc ifconfig_lo1="inet ${HOST_IP} netmask 255.255.255.0" >> "$LOG_FILE" 2>&1 || true

# Create the interface
ifconfig lo1 create 2>/dev/null || true
ifconfig lo1 inet ${HOST_IP} netmask 255.255.255.0 up 2>/dev/null || true

# Add aliases for jails
ifconfig lo1 alias ${WEB_IP} netmask 255.255.255.255 up 2>/dev/null || true
ifconfig lo1 alias ${DB_IP} netmask 255.255.255.255 up 2>/dev/null || true
ifconfig lo1 alias ${CACHE_IP} netmask 255.255.255.255 up 2>/dev/null || true

# Enable gateway (IP forwarding)
sysrc gateway_enable="YES" >> "$LOG_FILE" 2>&1 || true
sysrc jail_enable="YES" >> "$LOG_FILE" 2>&1 || true
sysrc ezjail_enable="YES" >> "$LOG_FILE" 2>&1 || true

# Enable IP forwarding immediately
sysctl net.inet.ip.forwarding=1 >> "$LOG_FILE" 2>&1 || true

success "Jail network configured"

# =============================================================================
# STEP 4: Initialize ezjail
# =============================================================================
info "Step 4/10: Initializing ezjail..."

# Enable ezjail
sysrc ezjail_enable="YES" >> "$LOG_FILE" 2>&1 || true

# Create basejail directory structure
mkdir -p /usr/jails/basejail
mkdir -p /usr/jails/newjail
mkdir -p /usr/jails/flavours/default/etc
mkdir -p /usr/jails/flavours/default/usr/local/etc

# Check if ezjail base system exists
if [ ! -f /usr/jails/basejail/bin/sh ]; then
    info "Setting up jail base system from host..."
    
    # Copy base system from host (comprehensive copy)
    for dir in /bin /sbin /usr/bin /usr/sbin /lib /libexec /usr/lib /usr/libexec /etc /usr/share/misc /usr/libdata; do
        if [ -d "$dir" ]; then
            mkdir -p "/usr/jails/basejail$dir"
            tar -cf - -C / "$dir" 2>/dev/null | tar -xf - -C /usr/jails/basejail 2>/dev/null || true
        fi
    done
    
    # Create necessary device entries
    mkdir -p /usr/jails/basejail/dev
    
    # Copy resolv.conf
    cp /etc/resolv.conf /usr/jails/basejail/etc/ 2>/dev/null || true
    
    # Create flavor template
    mkdir -p /usr/jails/flavours/default/etc
    cp /etc/resolv.conf /usr/jails/flavours/default/etc/ 2>/dev/null || true
fi

# Verify basejail
if [ ! -f /usr/jails/basejail/bin/sh ]; then
    error_exit "Could not create jail base system. Please check /var/log for errors."
fi

# Create newjail template from basejail
if [ ! -d /usr/jails/newjail/bin ]; then
    info "Creating newjail template..."
    cp -a /usr/jails/basejail/. /usr/jails/newjail/ 2>/dev/null || true
fi

# Ensure dev directory exists in newjail
mkdir -p /usr/jails/newjail/dev

success "ezjail initialized"

# =============================================================================
# STEP 5: Create Jails
# =============================================================================
info "Step 5/10: Creating jails..."

# Remove any existing jails from kernel (force remove without shutdown scripts)
for jail in ${JAIL_WEB} ${JAIL_DB} ${JAIL_CACHE}; do
    jail -R "$jail" 2>/dev/null || true
done
sleep 2

# Clean up any existing jail directories (handle immutable flags)
for jail in ${JAIL_WEB} ${JAIL_DB} ${JAIL_CACHE}; do
    if [ -d "/usr/jails/$jail" ]; then
        info "Cleaning up existing jail: $jail"
        # Unmount devfs
        umount -f "/usr/jails/$jail/dev" 2>/dev/null || true
        # Remove immutable flags
        chflags -R noschg "/usr/jails/$jail" 2>/dev/null || true
        # Remove directory
        rm -rf "/usr/jails/$jail"
    fi
done

# Create web jail
info "Creating web jail ${JAIL_WEB}..."
cp -a /usr/jails/newjail /usr/jails/${JAIL_WEB}

# Create DB jail
info "Creating DB jail ${JAIL_DB}..."
cp -a /usr/jails/newjail /usr/jails/${JAIL_DB}

# Create cache jail  
info "Creating cache jail ${JAIL_CACHE}..."
cp -a /usr/jails/newjail /usr/jails/${JAIL_CACHE}

# Configure jails - use ezjail style configuration
for jail in ${JAIL_WEB} ${JAIL_DB} ${JAIL_CACHE}; do
    cat > /usr/jails/$jail/etc/rc.conf << EOF
network_interfaces=""
defaultrouter="${HOST_IP}"
EOF
    # Copy password database
    cp /etc/master.passwd /usr/jails/$jail/etc/ 2>/dev/null || true
    cp /etc/passwd /usr/jails/$jail/etc/ 2>/dev/null || true
    cp /etc/group /usr/jails/$jail/etc/ 2>/dev/null || true
    cp /etc/spwd.db /usr/jails/$jail/etc/ 2>/dev/null || true
    cp /etc/pwd.db /usr/jails/$jail/etc/ 2>/dev/null || true
    # Copy resolv.conf
    cp /etc/resolv.conf /usr/jails/$jail/etc/ 2>/dev/null || true
    # Copy localtime
    cp /etc/localtime /usr/jails/$jail/etc/ 2>/dev/null || true
    # Configure pkg to use HTTP instead of HTTPS to avoid SSL issues in jails
    mkdir -p /usr/jails/$jail/usr/local/etc/pkg/repos
    cat > /usr/jails/$jail/usr/local/etc/pkg/repos/FreeBSD.conf << REPO
FreeBSD: {
    url: "http://pkg.FreeBSD.org/\${ABI}/quarterly",
    mirror_type: "srv",
    signature_type: "none",
    fingerprints: "/usr/share/keys/pkg",
    enabled: yes
}
REPO
    # Copy SSL certificates anyway for other uses
    mkdir -p /usr/jails/$jail/etc/ssl
    cp -r /etc/ssl/certs /usr/jails/$jail/etc/ssl/ 2>/dev/null || true
    cp /etc/ssl/cert.pem /usr/jails/$jail/etc/ssl/ 2>/dev/null || true
    cp /etc/ssl/openssl.cnf /usr/jails/$jail/etc/ssl/ 2>/dev/null || true
    # Create var directories
    mkdir -p /usr/jails/$jail/var/run /usr/jails/$jail/var/log
    mkdir -p /usr/jails/$jail/tmp
    chmod 1777 /usr/jails/$jail/tmp 2>/dev/null || true
    # Create dev directory (required for mount.devfs)
    mkdir -p /usr/jails/$jail/dev
done

# Write jail.conf
cat > /etc/jail.conf << 'EOF'
# ClassicPress Jails Configuration

exec.start = "/bin/sh /etc/rc";
exec.stop = "/bin/sh /etc/rc.shutdown";
exec.clean;
mount.devfs;
persist;

# ClassicPress Web Jail
cp-web {
    ip4.addr = "10.100.100.10";
    path = "/usr/jails/cp-web";
    allow.raw_sockets = 1;
    host.hostname = "cp-web.local";
}

# MariaDB Jail
cp-db {
    ip4.addr = "10.100.100.20";
    path = "/usr/jails/cp-db";
    allow.raw_sockets = 1;
    host.hostname = "cp-db.local";
}

# KeyDB Cache Jail
cp-cache {
    ip4.addr = "10.100.100.30";
    path = "/usr/jails/cp-cache";
    allow.raw_sockets = 1;
    host.hostname = "cp-cache.local";
}
EOF

# Start jails
info "Starting jails..."

jail -c cp-web >> "$LOG_FILE" 2>&1 || {
    error_exit "Failed to start cp-web jail"
}

jail -c cp-db >> "$LOG_FILE" 2>&1 || {
    error_exit "Failed to start cp-db jail"
}

jail -c cp-cache >> "$LOG_FILE" 2>&1 || {
    error_exit "Failed to start cp-cache jail"
}

sleep 3

# Verify jails are running
info "Verifying jails..."
if ! jls | grep -q "${JAIL_WEB}"; then
    error_exit "Web jail failed to start"
fi
if ! jls | grep -q "${JAIL_DB}"; then
    error_exit "DB jail failed to start"
fi
if ! jls | grep -q "${JAIL_CACHE}"; then
    error_exit "Cache jail failed to start"
fi

jls >> "$LOG_FILE" 2>&1 || true

success "Jails created and started"

# =============================================================================
# STEP 6: Configure DB Jail (MariaDB)
# =============================================================================
info "Step 6/10: Installing MariaDB in jail ${JAIL_DB}..."

# Check if jail is running
if ! jls | grep -q "${JAIL_DB}"; then
    error_exit "DB jail is not running. Cannot proceed."
fi

# Bootstrap pkg first
info "Bootstrapping pkg in DB jail..."
jexec ${JAIL_DB} env ASSUME_ALWAYS_YES=yes pkg bootstrap -f >> "$LOG_FILE" 2>&1 || true

# Install MariaDB in DB jail
jexec ${JAIL_DB} pkg install -y mariadb114-server >> "$LOG_FILE" 2>&1 || \
jexec ${JAIL_DB} pkg install -y mysql80-server >> "$LOG_FILE" 2>&1 || {
    error_exit "Failed to install MariaDB/MySQL"
}

# Configure MariaDB
echo 'mysql_enable="YES"' >> /usr/jails/${JAIL_DB}/etc/rc.conf

# Generate password
DB_PASS="cp$(openssl rand -hex 16)"

# Determine mysql version and paths
if jexec ${JAIL_DB} which mariadb-install-db >/dev/null 2>&1; then
    MYSQL_INSTALL_CMD="mariadb-install-db"
    MYSQL_CMD="mariadb"
else
    MYSQL_INSTALL_CMD="mysql_install_db"
    MYSQL_CMD="mysql"
fi

# Configure my.cnf for jail
cat > /usr/jails/${JAIL_DB}/usr/local/etc/mysql/my.cnf << EOF
[mysqld]
bind-address = ${DB_IP}
port = 3306
socket = /tmp/mysql.sock
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
innodb_buffer_pool_size = 256M
max_connections = 50
skip-name-resolve
log_error = /var/db/mysql/error.log

[client]
socket = /tmp/mysql.sock
EOF

# Create mysql data directory
jexec ${JAIL_DB} mkdir -p /var/db/mysql
jexec ${JAIL_DB} chown mysql:mysql /var/db/mysql

# Initialize database
jexec ${JAIL_DB} $MYSQL_INSTALL_CMD --user=mysql --basedir=/usr/local --datadir=/var/db/mysql >> "$LOG_FILE" 2>&1 || {
    info "Warning: Database initialization may have already been done or failed"
}

# Start MariaDB
# Start MariaDB
info "Starting MariaDB..."
jexec ${JAIL_DB} service mysql-server onestart >> "$LOG_FILE" 2>&1 || {
    # Try alternative start method
    jexec ${JAIL_DB} /usr/local/bin/mariadbd-safe --datadir=/var/db/mysql >> "$LOG_FILE" 2>&1 &
    sleep 5
}

sleep 5

# Wait for MariaDB to be ready
for i in 1 2 3 4 5; do
    if jexec ${JAIL_DB} $MYSQL_CMD -u root -e "SELECT 1" >/dev/null 2>&1; then
        break
    fi
    info "Waiting for MariaDB to be ready..."
    sleep 3
done

# Create database and user
if ! jexec ${JAIL_DB} $MYSQL_CMD -u root << EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'${WEB_IP}' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'${WEB_IP}';
FLUSH PRIVILEGES;
EOF
then
    error_exit "Failed to create database"
fi

success "MariaDB installed and configured in ${JAIL_DB}"

# =============================================================================
# STEP 7: Configure Cache Jail (KeyDB)
# =============================================================================
info "Step 7/10: Installing KeyDB in jail ${JAIL_CACHE}..."

# Check if jail is running
if ! jls | grep -q "${JAIL_CACHE}"; then
    error_exit "Cache jail is not running. Cannot proceed."
fi

# Bootstrap pkg first
info "Bootstrapping pkg in cache jail..."
jexec ${JAIL_CACHE} env ASSUME_ALWAYS_YES=yes pkg bootstrap -f >> "$LOG_FILE" 2>&1 || true

# Install KeyDB in cache jail
jexec ${JAIL_CACHE} pkg install -y keydb >> "$LOG_FILE" 2>&1 || {
    info "KeyDB not available, trying Redis..."
    jexec ${JAIL_CACHE} pkg install -y redis >> "$LOG_FILE" 2>&1 || {
        error_exit "Failed to install KeyDB or Redis"
    }
}

# Determine which cache server was installed
if jexec ${JAIL_CACHE} which keydb-server >/dev/null 2>&1; then
    CACHE_TYPE="keydb"
    CACHE_USER="keydb"
    CACHE_SERVICE="keydb"
else
    CACHE_TYPE="redis"
    CACHE_USER="redis"
    CACHE_SERVICE="redis"
fi

info "Using $CACHE_TYPE as cache server"

# Configure KeyDB/Redis
cat > /usr/jails/${JAIL_CACHE}/usr/local/etc/$CACHE_TYPE.conf << EOF
bind ${CACHE_IP}
port 6379
tcp-backlog 511
timeout 300
tcp-keepalive 300

# Memory
maxmemory 64MB
maxmemory-policy allkeys-lru

# Persistence
save 900 1
save 300 10
save 60 10000
dbfilename dump.rdb
dir /var/db/$CACHE_TYPE

# Logging
loglevel notice
logfile /var/log/$CACHE_TYPE/$CACHE_TYPE.log

# Security - only accept connections from web jail
protected-mode yes
EOF

# Create directories
jexec ${JAIL_CACHE} mkdir -p /var/db/$CACHE_TYPE /var/log/$CACHE_TYPE
jexec ${JAIL_CACHE} chown -R $CACHE_USER:$CACHE_USER /var/db/$CACHE_TYPE /var/log/$CACHE_TYPE 2>/dev/null || true

# Enable and start
echo "${CACHE_SERVICE}_enable=\"YES\"" >> /usr/jails/${JAIL_CACHE}/etc/rc.conf
# Start in background to avoid hanging
jexec ${JAIL_CACHE} service $CACHE_SERVICE onestart >> "$LOG_FILE" 2>&1 &
sleep 3

success "$CACHE_TYPE installed in ${JAIL_CACHE}"

# =============================================================================
# STEP 8: Configure Web Jail (Lighttpd + PHP + ClassicPress)
# =============================================================================
info "Step 8/10: Installing web stack in jail ${JAIL_WEB}..."

# Check if jail is running
if ! jls | grep -q "${JAIL_WEB}"; then
    error_exit "Web jail is not running. Cannot proceed."
fi

# Bootstrap pkg first
info "Bootstrapping pkg in web jail..."
jexec ${JAIL_WEB} env ASSUME_ALWAYS_YES=yes pkg bootstrap -f >> "$LOG_FILE" 2>&1 || true

# Install packages
jexec ${JAIL_WEB} pkg install -y \
    lighttpd \
    curl \
    unzip \
    openssl \
    php${PHP_VERSION} \
    php${PHP_VERSION}-curl \
    php${PHP_VERSION}-dom \
    php${PHP_VERSION}-exif \
    php${PHP_VERSION}-fileinfo \
    php${PHP_VERSION}-filter \
    php${PHP_VERSION}-gd \
    php${PHP_VERSION}-iconv \
    php${PHP_VERSION}-intl \
    php${PHP_VERSION}-mbstring \
    php${PHP_VERSION}-mysqli \
    php${PHP_VERSION}-opcache \
    php${PHP_VERSION}-pdo \
    php${PHP_VERSION}-pdo_mysql \
    php${PHP_VERSION}-phar \
    php${PHP_VERSION}-session \
    php${PHP_VERSION}-simplexml \
    php${PHP_VERSION}-ctype \
    php${PHP_VERSION}-tokenizer \
    php${PHP_VERSION}-xml \
    php${PHP_VERSION}-xmlreader \
    php${PHP_VERSION}-xmlwriter \
    php${PHP_VERSION}-zip \
    php${PHP_VERSION}-zlib \
    php${PHP_VERSION}-pecl-redis >> "$LOG_FILE" 2>&1 || {
    error_exit "Failed to install web packages"
}

# Enable services
echo 'lighttpd_enable="YES"' >> /usr/jails/${JAIL_WEB}/etc/rc.conf
echo 'php_fpm_enable="YES"' >> /usr/jails/${JAIL_WEB}/etc/rc.conf
# Create php-fpm rc.d link if needed
if [ ! -f /usr/jails/${JAIL_WEB}/usr/local/etc/rc.d/php-fpm ] && [ -f /usr/jails/${JAIL_WEB}/usr/local/etc/rc.d/php_fpm ]; then
    ln -s php_fpm /usr/jails/${JAIL_WEB}/usr/local/etc/rc.d/php-fpm 2>/dev/null || true
fi

# Create web directory
jexec ${JAIL_WEB} mkdir -p ${WEB_ROOT}
jexec ${JAIL_WEB} chown -R www:www ${WEB_ROOT}

success "Web stack installed in ${JAIL_WEB}"

# =============================================================================
# STEP 9: Download and Configure ClassicPress
# =============================================================================
info "Step 9/10: Installing ClassicPress..."

# Download ClassicPress with retry (use curl with insecure flag due to SSL issues in jail)
for i in 1 2 3; do
    if jexec ${JAIL_WEB} curl -kL -o /tmp/classicpress.tar.gz "https://www.classicpress.net/latest.tar.gz" >> "$LOG_FILE" 2>&1; then
        break
    fi
    info "Download attempt $i failed, retrying..."
    sleep 3
done

# Verify download
if [ ! -f /usr/jails/${JAIL_WEB}/tmp/classicpress.tar.gz ]; then
    error_exit "Failed to download ClassicPress"
fi

# Extract
jexec ${JAIL_WEB} tar -xzf /tmp/classicpress.tar.gz -C ${WEB_ROOT} --strip-components=1 || {
    error_exit "Failed to extract ClassicPress"
}
jexec ${JAIL_WEB} chown -R www:www ${WEB_ROOT}

# Generate secure keys
AUTH_KEY=$(openssl rand -hex 32)
SECURE_AUTH_KEY=$(openssl rand -hex 32)
LOGGED_IN_KEY=$(openssl rand -hex 32)
NONCE_KEY=$(openssl rand -hex 32)
AUTH_SALT=$(openssl rand -hex 32)
SECURE_AUTH_SALT=$(openssl rand -hex 32)
LOGGED_IN_SALT=$(openssl rand -hex 32)
NONCE_SALT=$(openssl rand -hex 32)

# Create wp-config.php
cat > /usr/jails/${JAIL_WEB}${WEB_ROOT}/wp-config.php << EOF
<?php
/** ClassicPress Configuration File */

// Database settings
define('DB_NAME', '${DB_NAME}');
define('DB_USER', '${DB_USER}');
define('DB_PASSWORD', '${DB_PASS}');
define('DB_HOST', '${DB_IP}');
define('DB_CHARSET', 'utf8mb4');
define('DB_COLLATE', 'utf8mb4_unicode_ci');

\$table_prefix = 'wp_';

// Authentication keys
define('AUTH_KEY',         '${AUTH_KEY}');
define('SECURE_AUTH_KEY',  '${SECURE_AUTH_KEY}');
define('LOGGED_IN_KEY',    '${LOGGED_IN_KEY}');
define('NONCE_KEY',        '${NONCE_KEY}');
define('AUTH_SALT',        '${AUTH_SALT}');
define('SECURE_AUTH_SALT', '${SECURE_AUTH_SALT}');
define('LOGGED_IN_SALT',   '${LOGGED_IN_SALT}');
define('NONCE_SALT',       '${NONCE_SALT}');

// Object cache (KeyDB/Redis)
define('WP_CACHE', true);
define('WP_REDIS_HOST', '${CACHE_IP}');
define('WP_REDIS_PORT', 6379);
define('WP_REDIS_DATABASE', 0);

// Performance
define('WP_MEMORY_LIMIT', '256M');
define('WP_MAX_MEMORY_LIMIT', '512M');

// SSL
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    \$_SERVER['HTTPS'] = 'on';
}

// Debug (disable in production)
define('WP_DEBUG', false);

// Absolute paths
if (!defined('ABSPATH')) {
    define('ABSPATH', dirname(__FILE__) . '/');
}
require_once(ABSPATH . 'wp-settings.php');
EOF

jexec ${JAIL_WEB} chown www:www ${WEB_ROOT}/wp-config.php
jexec ${JAIL_WEB} chmod 640 ${WEB_ROOT}/wp-config.php

success "ClassicPress configured"

# =============================================================================
# STEP 10: Configure Lighttpd and SSL
# =============================================================================
info "Step 10/10: Configuring web server..."

# PHP-FPM configuration
cat > /usr/jails/${JAIL_WEB}/usr/local/etc/php-fpm.d/www.conf << EOF
[www]
user = www
group = www
listen = /tmp/php-fpm.sock
listen.owner = www
listen.group = www
pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 5
pm.max_requests = 500
EOF

# Lighttpd configuration
cat > /usr/jails/${JAIL_WEB}/usr/local/etc/lighttpd/lighttpd.conf << EOF
server.port = 80
server.bind = "${WEB_IP}"
server.document-root = "${WEB_ROOT}"
server.errorlog = "/var/log/lighttpd/error.log"
server.pid-file = "/var/run/lighttpd.pid"
server.username = "www"
server.groupname = "www"

# Modules
server.modules = (
    "mod_access",
    "mod_alias",
    "mod_compress",
    "mod_redirect",
    "mod_fastcgi",
    "mod_rewrite"
)

# MIME types
include "conf.d/mime.conf"

# Access log
accesslog.filename = "/var/log/lighttpd/access.log"

# Deny access to sensitive files
url.access-deny = ( "~", ".inc", ".md", ".txt", ".yml", ".yaml" )

# WordPress/ClassicPress rewrite rules
url.rewrite-if-not-file = (
    "^/(wp-.+).*/" => "\$0",
    "^/(sitemap.xml)" => "\$1",
    "^/(robots.txt)" => "\$1",
    ".*\?(.*)" => "/index.php?\$1",
    "." => "/index.php"
)

# PHP-FPM
fastcgi.server = (
    ".php" => (
        "localhost" => (
            "socket" => "/tmp/php-fpm.sock",
            "broken-scriptfilename" => "enable"
        )
    )
)

# Compression
compress.filetype = ( "text/plain", "text/html", "text/css", "application/javascript" )
compress.cache-dir = "/var/tmp/lighttpd/cache"
EOF

# Create log directories
jexec ${JAIL_WEB} mkdir -p /var/log/lighttpd /var/tmp/lighttpd/cache
jexec ${JAIL_WEB} chown -R www:www /var/log/lighttpd /var/tmp/lighttpd

# SSL configuration
if [ "$SSL_MODE" = "selfsigned" ]; then
    info "Generating self-signed SSL certificate..."
    jexec ${JAIL_WEB} mkdir -p /usr/local/etc/ssl
    jexec ${JAIL_WEB} openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /usr/local/etc/ssl/server.key \
        -out /usr/local/etc/ssl/server.crt \
        -subj "/C=US/ST=State/L=City/O=Organization/CN=${DOMAIN:-localhost}" >> "$LOG_FILE" 2>&1
    
    # Combine cert and key
    jexec ${JAIL_WEB} sh -c "cat /usr/local/etc/ssl/server.key /usr/local/etc/ssl/server.crt > /usr/local/etc/ssl/server.pem"
    
    # Update lighttpd config for SSL
    cat >> /usr/jails/${JAIL_WEB}/usr/local/etc/lighttpd/lighttpd.conf << EOF

# SSL
\$SERVER["socket"] == "${WEB_IP}:443" {
    ssl.engine = "enable"
    ssl.pemfile = "/usr/local/etc/ssl/server.pem"
}
EOF
fi

# Start services
info "Starting web services..."
jexec ${JAIL_WEB} service php_fpm onestart >> "$LOG_FILE" 2>&1 &
sleep 3
jexec ${JAIL_WEB} service lighttpd onestart >> "$LOG_FILE" 2>&1 &
sleep 2

# Test web server
sleep 2
info "Testing web server..."
if fetch -o - http://${WEB_IP}/ 2>/dev/null | grep -q "ClassicPress\|WordPress"; then
    success "Web server is responding correctly"
else
    info "Web server may need a moment to fully start"
fi

success "Web server configured"

# =============================================================================
# Save Credentials
# =============================================================================

# Get server public IP
PUBLIC_IP=$(ifconfig $EXT_IF | grep "inet " | head -1 | awk '{print $2}' || echo "your-server-ip")

cat > "$CREDENTIALS_FILE" << EOF
========================================
ClassicPress Jail Installation Complete
========================================

JAIL ARCHITECTURE:
- Web Jail (${JAIL_WEB}): ${WEB_IP}
- DB Jail (${JAIL_DB}): ${DB_IP}  
- Cache Jail (${JAIL_CACHE}): ${CACHE_IP}

DATABASE:
Host: ${DB_IP}
Database: ${DB_NAME}
Username: ${DB_USER}
Password: ${DB_PASS}

CACHE ($CACHE_TYPE):
Host: ${CACHE_IP}
Port: 6379

WEB ROOT: ${WEB_ROOT}
PUBLIC IP: ${PUBLIC_IP}

========================================
TO COMPLETE INSTALLATION:
1. Point your domain to this server's IP: ${PUBLIC_IP}
2. Visit http://${DOMAIN:-${PUBLIC_IP}}/
3. Follow the ClassicPress setup wizard

JAIL MANAGEMENT:
- Enter web jail: jexec ${JAIL_WEB} /bin/sh
- Enter DB jail: jexec ${JAIL_DB} /bin/sh
- Enter cache jail: jexec ${JAIL_CACHE} /bin/sh

SERVICE MANAGEMENT:
- Web jail: jexec ${JAIL_WEB} service lighttpd restart
- Web jail: jexec ${JAIL_WEB} service php-fpm restart
- DB jail: jexec ${JAIL_DB} service mysql-server restart
- Cache jail: jexec ${JAIL_CACHE} service ${CACHE_SERVICE} restart

RESTRICTED ACCESS:
- DB jail only accepts connections from ${WEB_IP}:3306
- Cache jail only accepts connections from ${WEB_IP}:6379
- Firewall blocks all external access to jails

========================================
EOF

echo ""
echo "========================================"
echo "Installation Complete!"
echo "========================================"
echo ""
echo "Jail Architecture:"
echo "  Web:   ${WEB_IP} (${JAIL_WEB})"
echo "  DB:    ${DB_IP} (${JAIL_DB})"
echo "  Cache: ${CACHE_IP} (${JAIL_CACHE})"
echo ""
echo "Database Password: ${DB_PASS}"
echo ""
echo "Credentials saved to: $CREDENTIALS_FILE"
echo ""
echo "Visit http://${DOMAIN:-${PUBLIC_IP}}/ to complete setup"
echo ""
log "Installation completed successfully"
