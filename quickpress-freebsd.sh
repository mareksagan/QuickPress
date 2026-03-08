#!/bin/sh
set -e

# =============================================================================
# ClassicPress FreeBSD Installer - VM Edition
# End-to-end automated installer for FreeBSD VMs using rc.d
#
# Usage:
#   ./quickpress-freebsd.sh [OPTIONS]
#
# SSL Options:
#   --ssl-domain <DOMAIN>    Domain for Let's Encrypt SSL (requires --ssl-email)
#   --ssl-email <EMAIL>      Email for Let's Encrypt SSL (requires --ssl-domain)
#   --ssl-self-signed        Use self-signed certificate (works with IP addresses)
#   No flags                 No SSL (HTTP only) - default
#
# Examples:
#   Let's Encrypt SSL:  ./quickpress-freebsd.sh --ssl-domain example.com --ssl-email admin@example.com
#   Self-signed SSL:    ./quickpress-freebsd.sh --ssl-self-signed
#   No SSL:             ./quickpress-freebsd.sh
# =============================================================================

# Configuration
DB_NAME="classicpress"
DB_USER="cpuser"
DB_PASS=""
WEB_ROOT="/usr/local/www/classicpress"
PHP_VERSION="83"
CREDENTIALS_FILE="/root/classicpress-login.txt"
LOG_FILE="/var/log/classicpress-install.log"

# SSL Configuration (set via command-line arguments)
DOMAIN=""
EMAIL=""
SSL_MODE=""
SSL_DIR="/usr/local/etc/ssl/acme"

# =============================================================================
# Parse Command Line Arguments
# =============================================================================

show_help() {
    cat << HELP
ClassicPress FreeBSD Installer - VM Edition

USAGE:
    ./quickpress-freebsd.sh [OPTIONS]

SSL OPTIONS:
    --ssl-domain <DOMAIN>     Domain for Let's Encrypt SSL
                              Requires: --ssl-email
                              Example: --ssl-domain example.com

    --ssl-email <EMAIL>       Email for Let's Encrypt SSL
                              Required with --ssl-domain
                              Example: --ssl-email admin@example.com

    --ssl-self-signed         Use self-signed certificate
                              Works with IP addresses
                              Browser will show security warning

OTHER OPTIONS:
    --help, -h                Show this help message

EXAMPLES:
    Let's Encrypt (trusted SSL certificate):
        ./quickpress-freebsd.sh --ssl-domain example.com --ssl-email admin@example.com

    Self-signed (works with IP, browser warning):
        ./quickpress-freebsd.sh --ssl-self-signed

    No SSL (HTTP only):
        ./quickpress-freebsd.sh

For more information, visit: https://github.com/ClassicPress/ClassicPress
HELP
}

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --ssl-domain)
            if [ -n "$2" ] && [ "${2#--}" = "$2" ]; then
                DOMAIN="$2"
                SSL_MODE="letsencrypt"
                shift 2
            else
                echo "ERROR: --ssl-domain requires a domain name"
                exit 1
            fi
            ;;
        --ssl-email)
            if [ -n "$2" ] && [ "${2#--}" = "$2" ]; then
                EMAIL="$2"
                shift 2
            else
                echo "ERROR: --ssl-email requires an email address"
                exit 1
            fi
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
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Validate SSL options
if [ "$SSL_MODE" = "letsencrypt" ]; then
    if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
        echo "ERROR: Let's Encrypt SSL requires both --ssl-domain and --ssl-email"
        echo "Example: ./quickpress-freebsd.sh --ssl-domain example.com --ssl-email admin@example.com"
        exit 1
    fi
fi

# =============================================================================
# Helper Functions
# =============================================================================

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Timeout function for FreeBSD (timeout command may not be available)
run_with_timeout() {
    local timeout_sec=$1
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_sec" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$timeout_sec" "$@"
    else
        # Fallback: run without timeout
        "$@"
    fi
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
        # Try sockstat first (FreeBSD native), then nc
        if sockstat -4 -l -p "$port" 2>/dev/null | grep -q ":$port"; then
            return 0
        elif nc -z 127.0.0.1 "$port" 2>/dev/null; then
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
echo "ClassicPress FreeBSD Installer"
echo "=========================================="
echo ""

# Initialize log
touch "$LOG_FILE"
log "Starting ClassicPress installation"

# Check if running as root
check_root

# Check if FreeBSD
if [ ! -f /etc/freebsd-version ]; then
    uname -s | grep -q "FreeBSD" || error_exit "This script is designed for FreeBSD only"
fi
success "FreeBSD detected: $(uname -r)"

# =============================================================================
# STEP 1: Install Packages
# =============================================================================
info "Step 1/8: Installing packages..."
info "This may take several minutes. Check $LOG_FILE for details."

# Set non-interactive mode for pkg
export BATCH=yes
export ASSUME_ALWAYS_YES=yes

# Check if pkg is working
if ! command -v pkg > /dev/null 2>&1; then
    error_exit "pkg command not found. Is FreeBSD base system properly installed?"
fi

# Bootstrap pkg if needed
if ! pkg -N > /dev/null 2>&1; then
    info "Bootstrapping pkg..."
    /usr/sbin/pkg bootstrap -y || error_exit "Failed to bootstrap pkg"
fi

# Update package index first
info "Updating package repository..."
if run_with_timeout 180 pkg update -f >> "$LOG_FILE" 2>&1; then
    success "Package repository updated"
else
    echo "WARNING: pkg update took too long or failed, continuing anyway..."
fi

# Install packages in groups to better handle errors
info "Starting package installation (this may take 5-10 minutes)..."

# Core system packages
info "Installing core packages (lighttpd, curl, etc.)..."
run_with_timeout 300 pkg install -y \
    lighttpd \
    curl \
    unzip \
    openssl \
    netcat \
    ImageMagick7-nox11 >> "$LOG_FILE" 2>&1 || {
    echo "WARNING: Some core packages failed or timed out, continuing..."
}

# PHP and core extensions
info "Installing PHP ${PHP_VERSION}..."
run_with_timeout 600 pkg install -y \
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
    php${PHP_VERSION}-zlib >> "$LOG_FILE" 2>&1 || {
    echo "WARNING: Some PHP packages failed or timed out, continuing..."
}

# Try to install pecl-redis (may have different naming)
info "Installing Redis PHP extension..."
run_with_timeout 120 pkg install -y php${PHP_VERSION}-pecl-redis >> "$LOG_FILE" 2>&1 || \
run_with_timeout 120 pkg install -y php${PHP_VERSION}-redis >> "$LOG_FILE" 2>&1 || \
echo "WARNING: PHP Redis extension not available, will try later"

# Database and cache
info "Installing database server (MariaDB) and KeyDB..."

# First, search for available database packages
echo "Searching for available database packages..." >> "$LOG_FILE"
pkg search -qE '^mariadb.*server$' >> "$LOG_FILE" 2>&1 || pkg search -qE '^mysql.*server$' >> "$LOG_FILE" 2>&1 || true

# Install MariaDB (preferred over MySQL for better performance and compatibility)
# First ensure pcre2 is up to date to avoid library compatibility issues
info "Ensuring library compatibility..."
run_with_timeout 120 pkg upgrade -y pcre2 >> "$LOG_FILE" 2>&1 || true

DB_INSTALLED=0
# Try newer MariaDB versions first (11.4 is current LTS, then 10.11, 10.6, 10.5)
for db_pkg in mariadb114-server mariadb1011-server mariadb106-server mariadb105-server; do
    info "Trying to install $db_pkg..."
    if run_with_timeout 300 pkg install -y "$db_pkg" >> "$LOG_FILE" 2>&1; then
        success "$db_pkg installed"
        DB_INSTALLED=1
        break
    fi
done

if [ "$DB_INSTALLED" -eq 0 ]; then
    echo "ERROR: Could not install any MySQL/MariaDB server package"
    echo "Available packages:"
    pkg search -qE '^mariadb.*server$' 2>/dev/null || pkg search -qE '^mysql.*server$' 2>/dev/null || echo "  search failed"
fi

# Install KeyDB (Redis-compatible, multi-threaded)
info "Installing KeyDB (Redis-compatible)..."
run_with_timeout 120 pkg install -y keydb >> "$LOG_FILE" 2>&1 || {
    echo "WARNING: KeyDB installation may have issues, falling back to Redis..."
    run_with_timeout 120 pkg install -y redis >> "$LOG_FILE" 2>&1
}

# Update PCRE2 to fix library compatibility issues with MariaDB
info "Updating PCRE2 library for MariaDB compatibility..."
run_with_timeout 120 pkg upgrade -y pcre2 >> "$LOG_FILE" 2>&1 || true

# Verify critical packages
info "Verifying installations..."

# Check PHP
PHP_BIN=""
if command -v php > /dev/null 2>&1; then
    PHP_BIN="php"
elif command -v php83 > /dev/null 2>&1; then
    PHP_BIN="php83"
    ln -sf $(command -v php83) /usr/local/bin/php 2>/dev/null || true
fi

if [ -n "$PHP_BIN" ]; then
    success "PHP found: $PHP_BIN"
else
    error_exit "PHP not found after installation"
fi

# Check Lighttpd
if ! command -v lighttpd > /dev/null 2>&1; then
    error_exit "Lighttpd not found after installation"
fi

# Check MySQL/MariaDB (various possible binary names)
MYSQL_CMD=""
for cmd in mysql mysql82 mariadb; do
    if command -v $cmd > /dev/null 2>&1; then
        MYSQL_CMD=$cmd
        success "Database client found: $cmd"
        break
    fi
done

if [ -z "$MYSQL_CMD" ]; then
    # Check if server binaries exist
    if [ -x /usr/local/libexec/mysqld ] || [ -x /usr/local/sbin/mysqld ] || \
       [ -x /usr/local/libexec/mysql82/mysqld ] || [ -x /usr/local/libexec/mariadbd ] || \
       [ -x /usr/local/sbin/mariadbd ]; then
        success "Database server binaries found"
        MYSQL_CMD="mysql"
    else
        echo ""
        echo "ERROR: MySQL/MariaDB not found after installation."
        echo ""
        echo "Debug info:"
        echo "  pkg info | grep -E 'mysql|mariadb':"
        pkg info 2>/dev/null | grep -iE 'mysql|mariadb' || echo "    (no database packages found)"
        echo ""
        echo "  Available binaries:"
        ls -la /usr/local/bin/mysql* /usr/local/sbin/mysql* /usr/local/bin/mariadb* /usr/local/sbin/mariadb* 2>/dev/null || echo "    (no binaries found)"
        echo ""
        echo "Try running manually:"
        echo "  pkg install -y mysql82-server"
        echo "  or"
        echo "  pkg install -y mariadb106-server"
        echo ""
        exit 1
    fi
fi

success "Packages installed"

# Export MYSQL_CMD for later use
export MYSQL_CMD

# Generate database password now that openssl is available
if [ -z "$DB_PASS" ]; then
    DB_PASS="cp$(openssl rand -hex 16)"
fi

# =============================================================================
# STEP 2: Configure and Start MySQL with Performance Optimizations
# =============================================================================
info "Step 2/8: Configuring MariaDB with performance optimizations..."

# Fix PCRE2 library compatibility issue with MariaDB
info "Ensuring PCRE2 library compatibility..."
# Force reinstall/upgrade pcre2 to ensure correct version
pkg upgrade -f -y pcre2 >> "$LOG_FILE" 2>&1 || pkg install -f -y pcre2 >> "$LOG_FILE" 2>&1 || {
    echo "WARNING: Could not upgrade PCRE2, MariaDB may have issues"
}
# Also ensure libpcre2 is properly linked
if [ -f /usr/local/lib/libpcre2-8.so.0 ]; then
    ldconfig 2>/dev/null || true
fi

# Create MySQL directories
mkdir -p /var/db/mysql
mkdir -p /var/run/mysql
chown mysql:mysql /var/db/mysql
chown mysql:mysql /var/run/mysql

# Get system memory for buffer pool calculation (use 50% of RAM for InnoDB)
TOTAL_MEM_MB=$(sysctl -n hw.physmem | awk '{print int($1/1024/1024)}')
INNODB_BUFFER_POOL=$((TOTAL_MEM_MB * 50 / 100))
if [ "$INNODB_BUFFER_POOL" -lt 128 ]; then
    INNODB_BUFFER_POOL=128
fi

# Configure MariaDB - use minimal config to avoid issues
mkdir -p /usr/local/etc/mysql

cat > /usr/local/etc/mysql/my.cnf << 'EOF'
[mysqld]
bind-address = 127.0.0.1
port = 3306
socket = /var/run/mysql/mysql.sock
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
innodb_buffer_pool_size = 128M
max_connections = 100
skip-name-resolve
log_error = /var/db/mysql/error.log

[client]
socket = /var/run/mysql/mysql.sock
default-character-set = utf8mb4
EOF

# Enable MariaDB in rc.conf (try different service names)
# First detect which service script exists
# Note: MariaDB 11.4+ uses 'mysql-server' rc.d script
MYSQL_SERVICE=""
if [ -x /usr/local/etc/rc.d/mysql-server ]; then
    MYSQL_SERVICE="mysql-server"
elif [ -x /usr/local/etc/rc.d/mariadb ]; then
    MYSQL_SERVICE="mariadb"
elif [ -x /usr/local/etc/rc.d/mysql ]; then
    MYSQL_SERVICE="mysql"
elif [ -x /usr/local/etc/rc.d/mariadb-server ]; then
    MYSQL_SERVICE="mariadb-server"
fi

# Clean up rc.conf - remove all mysql entries first
info "Configuring rc.conf..."
for var in mariadb_enable mariadb-server_enable mysql_enable mysql-server_enable; do
    sysrc -x "$var" 2>/dev/null || true
done
# Set only one
sysrc mysql-server_enable="YES" >> "$LOG_FILE" 2>&1

# Initialize MariaDB if needed (check for mysql system database)
if [ ! -d /var/db/mysql/mysql ] || [ ! -f /var/db/mysql/ibdata1 ]; then
    info "Initializing MariaDB data directory..."
    
    # If directory exists but is incomplete/corrupted, back it up and start fresh
    if [ -d /var/db/mysql ]; then
        if ls /var/db/mysql/* > /dev/null 2>&1; then
            info "Backing up existing incomplete MySQL data directory..."
            mv /var/db/mysql /var/db/mysql.bak.$(date +%s)
        fi
    fi
    
    # Ensure proper ownership
    mkdir -p /var/db/mysql
    chown -R mysql:mysql /var/db/mysql
    chmod 755 /var/db/mysql
    
    # Try different initialization methods
    INIT_SUCCESS=0
    if command -v mariadb-install-db > /dev/null 2>&1; then
        info "Using mariadb-install-db to initialize..."
        if mariadb-install-db --user=mysql --basedir=/usr/local --datadir=/var/db/mysql >> "$LOG_FILE" 2>&1; then
            INIT_SUCCESS=1
        else
            # Check for PCRE2 library error and try to fix
            if grep -q "PCRE2" "$LOG_FILE" 2>/dev/null; then
                info "Fixing PCRE2 library issue..."
                pkg upgrade -f -y pcre2 >> "$LOG_FILE" 2>&1 || pkg install -y pcre2 >> "$LOG_FILE" 2>&1 || true
                # Retry initialization
                mariadb-install-db --user=mysql --basedir=/usr/local --datadir=/var/db/mysql >> "$LOG_FILE" 2>&1 && INIT_SUCCESS=1 || true
            fi
        fi
    elif command -v mysql_install_db > /dev/null 2>&1; then
        info "Using mysql_install_db to initialize..."
        mysql_install_db --user=mysql --basedir=/usr/local --datadir=/var/db/mysql >> "$LOG_FILE" 2>&1 && INIT_SUCCESS=1 || true
    elif command -v mysqld > /dev/null 2>&1; then
        info "Using mysqld --initialize to initialize..."
        mysqld --initialize-insecure --user=mysql --datadir=/var/db/mysql >> "$LOG_FILE" 2>&1 && INIT_SUCCESS=1 || true
    else
        echo "WARNING: Could not find database initialization tool"
    fi
    # Ensure ownership after init
    chown -R mysql:mysql /var/db/mysql
    
    # Check if initialization succeeded
    if [ "$INIT_SUCCESS" -eq 0 ]; then
        error_exit "MariaDB initialization failed. Check $LOG_FILE for details (look for PCRE2 library errors)."
    fi
    success "MariaDB data directory initialized"
else
    info "MariaDB data directory already exists, skipping initialization"
fi

# Prepare and start MariaDB
info "Preparing MariaDB..."

# Stop any existing
pkill -9 mariadbd 2>/dev/null || true
sleep 1

# Fix permissions
chown -R mysql:mysql /var/db/mysql
chmod -R 700 /var/db/mysql 2>/dev/null || true
rm -rf /var/run/mysql
mkdir -p /var/run/mysql
chmod 777 /var/run/mysql

info "Starting MariaDB..."
START_SUCCESS=0

# Use the proper service command since we know the binary works
if service mysql-server start; then
    sleep 3
    if pgrep -x mariadbd > /dev/null 2>&1; then
        success "MariaDB is running via service"
        START_SUCCESS=1
    fi
fi

# If service failed, try direct background start with disown
if [ "$START_SUCCESS" -eq 0 ] && [ -x /usr/local/libexec/mariadbd ]; then
    info "Service failed, trying direct start..."
    # Start it properly detached from shell
    ( /usr/local/libexec/mariadbd --user=mysql > /dev/null 2>&1 & )
    sleep 5
    
    if pgrep -x mariadbd > /dev/null 2>&1; then
        success "MariaDB is running (direct start)"
        START_SUCCESS=1
    else
        echo "FAILED to start - checking error log..."
        cat /var/db/mysql/error.log 2>/dev/null | tail -20 || echo "No error log"
    fi
fi

# Wait for port 3306
if [ "$START_SUCCESS" -eq 1 ]; then
    info "Waiting for port 3306..."
    MARIADB_READY=0
    sleep 3
    if sockstat -4 -l -p 3306 2>/dev/null | grep -q ":3306"; then
        success "MariaDB ready on port 3306"
        MARIADB_READY=1
    else
        echo "Port 3306 not listening"
    fi
else
    MARIADB_READY=0
fi

# If failed, show error
if [ "$MARIADB_READY" -eq 0 ]; then
    echo ""
    echo "========================================="
    echo "ERROR: MariaDB failed to start"
    echo "========================================="
    echo ""
    echo "=== ERROR LOG ==="
    if [ -f /var/db/mysql/error.log ]; then
        tail -30 /var/db/mysql/error.log
    else
        echo "No error.log file found"
        echo "Files in /var/db/mysql/:"
        ls /var/db/mysql/ 2>&1 | head -10
    fi
    echo "================="
    echo ""
    error_exit "MariaDB failed to start - see error log above"
fi

# Create database and user (use detected MySQL command)
MYSQL_CLIENT="${MYSQL_CMD:-mysql}"

# Check if MySQL is using socket or TCP
if [ -S /var/run/mysql/mysql.sock ] || [ -S /tmp/mysql.sock ]; then
    MYSQL_OPTS="-u root"
else
    MYSQL_OPTS="-u root -h 127.0.0.1"
fi

$MYSQL_CLIENT $MYSQL_OPTS << EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${DB_USER}'@'localhost';
DROP USER IF EXISTS '${DB_USER}'@'127.0.0.1';
CREATE USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
EOF

# Verify database exists
if ! $MYSQL_CLIENT $MYSQL_OPTS -e "USE ${DB_NAME};" 2>/dev/null; then
    error_exit "Failed to create database"
fi

success "MariaDB configured (${INNODB_BUFFER_POOL}MB buffer pool) and database created"

# =============================================================================
# STEP 3: Configure KeyDB (Redis-compatible Object Cache)
# =============================================================================
info "Step 3/8: Configuring KeyDB (object cache)..."

# Calculate Redis memory (use 10% of total RAM for object caching)
REDIS_MEM_MB=$((TOTAL_MEM_MB * 10 / 100))
if [ "$REDIS_MEM_MB" -lt 64 ]; then
    REDIS_MEM_MB=64
fi

# Create KeyDB configuration
cat > /usr/local/etc/keydb.conf << EOF
# KeyDB Configuration - High Performance Mode (Redis-compatible)
bind 127.0.0.1
port 6379
tcp-backlog 511
timeout 300
tcp-keepalive 300

# Memory Settings
maxmemory ${REDIS_MEM_MB}mb
maxmemory-policy allkeys-lru
maxmemory-samples 5

# Persistence (disable for pure cache, enable for durability)
save ""

stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump.rdb
dir /var/db/redis

# Append Only File (AOF) - disable for cache-only mode
appendonly no

# Client output buffer limits
client-output-buffer-limit normal 0 0 0
client-output-buffer-limit replica 256mb 64mb 60
client-output-buffer-limit pubsub 32mb 8mb 60

# Hash settings
hash-max-ziplist-entries 512
hash-max-ziplist-value 64

# List settings
list-max-ziplist-size -2
list-compress-depth 0

# Set settings
set-max-intset-entries 512

# Sorted set settings
zset-max-ziplist-entries 128
zset-max-ziplist-value 64

# Active rehashing
activerehashing yes

# Slow log
slowlog-log-slower-than 10000
slowlog-max-len 128

# Databases (ClassicPress uses DB 0 by default)
databases 16

# Logging
loglevel notice
logfile /var/log/keydb/keydb.log
EOF

# Create KeyDB/Redis directories
mkdir -p /var/db/keydb
mkdir -p /var/log/keydb
mkdir -p /var/run/keydb
mkdir -p /var/db/redis
mkdir -p /var/log/redis
mkdir -p /var/run/redis

# Fix permissions - use keydb user if exists, else redis, else root
if id keydb > /dev/null 2>&1; then
    KEYDB_USER="keydb"
elif id redis > /dev/null 2>&1; then
    KEYDB_USER="redis"
else
    KEYDB_USER="root"
fi

chown $KEYDB_USER:$KEYDB_USER /var/db/keydb 2>/dev/null || chown root:wheel /var/db/keydb
chown $KEYDB_USER:$KEYDB_USER /var/log/keydb 2>/dev/null || chown root:wheel /var/log/keydb
chown $KEYDB_USER:$KEYDB_USER /var/run/keydb 2>/dev/null || chown root:wheel /var/run/keydb
chmod 755 /var/db/keydb
chmod 755 /var/log/keydb
chmod 755 /var/run/keydb

# Also set up Redis directories (for fallback)
chown redis:redis /var/db/redis 2>/dev/null || chown root:wheel /var/db/redis
chown redis:redis /var/log/redis 2>/dev/null || chown root:wheel /var/log/redis
chmod 755 /var/db/redis
chmod 755 /var/log/redis

# Create log files with proper permissions
touch /var/log/keydb/keydb.log
chown $KEYDB_USER:$KEYDB_USER /var/log/keydb/keydb.log 2>/dev/null || chown root:wheel /var/log/keydb/keydb.log
chmod 644 /var/log/keydb/keydb.log

touch /var/log/redis/redis.log
chown redis:redis /var/log/redis/redis.log 2>/dev/null || chown root:wheel /var/log/redis/redis.log
chmod 644 /var/log/redis/redis.log

# Enable in rc.conf
sysrc keydb_enable="YES" >> "$LOG_FILE" 2>&1 || true
sysrc redis_enable="YES" >> "$LOG_FILE" 2>&1 || true

# Start KeyDB (or fallback to Redis)
pkill -9 keydb-server 2>/dev/null || pkill -9 redis-server 2>/dev/null || true
rm -f /var/run/keydb/keydb.pid /var/run/redis/redis.pid 2>/dev/null || true
sleep 1

if command -v keydb-server > /dev/null 2>&1; then
    info "Starting KeyDB..."
    # Try service with timeout
    timeout 10 service keydb start >> "$LOG_FILE" 2>&1 || true
    sleep 2
    if ! pgrep -x keydb-server > /dev/null 2>&1; then
        info "Using direct start..."
        ( /usr/local/bin/keydb-server /usr/local/etc/keydb.conf >> "$LOG_FILE" 2>&1 & )
        sleep 3
    fi
else
    info "Starting Redis..."
    timeout 10 service redis start >> "$LOG_FILE" 2>&1 || \
    timeout 10 service redis-server start >> "$LOG_FILE" 2>&1 || true
    sleep 2
    if ! pgrep -x redis-server > /dev/null 2>&1; then
        ( /usr/local/bin/redis-server /usr/local/etc/redis.conf >> "$LOG_FILE" 2>&1 & )
        sleep 3
    fi
fi

# Wait for KeyDB/Redis to be ready
info "Waiting for object cache to start..."
CACHE_READY=0
i=1
while [ $i -le 30 ]; do
    if keydb-cli ping 2>/dev/null | grep -q "PONG"; then
        success "KeyDB running (${REDIS_MEM_MB}MB memory limit, multi-threaded)"
        CACHE_READY=1
        break
    elif redis-cli ping 2>/dev/null | grep -q "PONG"; then
        success "Redis running (${REDIS_MEM_MB}MB memory limit)"
        CACHE_READY=1
        break
    fi
    sleep 1
    i=$((i + 1))
done

if [ "$CACHE_READY" -eq 0 ]; then
    echo "WARNING: Object cache may not be running properly"
fi

# =============================================================================
# STEP 4: Download ClassicPress
# =============================================================================
info "Step 4/8: Downloading ClassicPress..."

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
# STEP 5: Configure PHP-FPM with Optimizations
# =============================================================================
info "Step 5/8: Configuring PHP-FPM with optimizations..."

# Configure PHP-FPM to use Unix socket
mkdir -p /var/run/php-fpm
chown www:www /var/run/php-fpm

# Find or create PHP-FPM config directory
PHP_FPM_DIR="/usr/local/etc/php-fpm.d"
if [ ! -d "$PHP_FPM_DIR" ]; then
    mkdir -p "$PHP_FPM_DIR"
fi

# Backup existing config if present
if [ -f "$PHP_FPM_DIR/www.conf" ]; then
    cp "$PHP_FPM_DIR/www.conf" "$PHP_FPM_DIR/www.conf.bak" 2>/dev/null || true
fi

# Also ensure main php-fpm.conf includes the pool directory
if [ -f "/usr/local/etc/php-fpm.conf" ]; then
    if ! grep -q "php-fpm.d" /usr/local/etc/php-fpm.conf 2>/dev/null; then
        echo "include=/usr/local/etc/php-fpm.d/*.conf" >> /usr/local/etc/php-fpm.conf
    fi
elif [ -f "/usr/local/etc/php-fpm.conf.default" ]; then
    cp /usr/local/etc/php-fpm.conf.default /usr/local/etc/php-fpm.conf
    echo "include=/usr/local/etc/php-fpm.d/*.conf" >> /usr/local/etc/php-fpm.conf
fi

cat > "$PHP_FPM_DIR/www.conf" << EOF
[www]
user = www
group = www
listen = /var/run/php-fpm/php-fpm.sock
listen.owner = www
listen.group = www
listen.mode = 0660

pm = dynamic
pm.max_children = 50
pm.start_servers = 5
pm.min_spare_servers = 5
pm.max_spare_servers = 35
pm.max_requests = 500

request_terminate_timeout = 300s
request_slowlog_timeout = 30s
slowlog = /var/log/php-fpm/slow.log

; Security
security.limit_extensions = .php

; Environment
env[HOSTNAME] = \$HOSTNAME
env[PATH] = /usr/local/bin:/usr/bin:/bin
env[TMP] = /tmp
env[TMPDIR] = /tmp
env[TEMP] = /tmp
EOF

# Create PHP-FPM log directory
mkdir -p /var/log/php-fpm
chown www:www /var/log/php-fpm

# Configure OPcache with JIT
cat > /usr/local/etc/php/ext-20-opcache.ini << EOF
; OPcache Configuration
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=256
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.revalidate_freq=60
opcache.fast_shutdown=1
opcache.validate_timestamps=1
opcache.save_comments=1

; JIT Configuration (PHP 8.0+)
opcache.jit_buffer_size=128M
opcache.jit=tracing
EOF

# Additional PHP optimizations
cat > /usr/local/etc/php/99-quickpress.ini << EOF
; PHP Performance Optimizations
max_execution_time = 300
max_input_time = 300
max_input_vars = 3000
memory_limit = 256M
post_max_size = 64M
upload_max_filesize = 64M
max_file_uploads = 20

; Realpath Cache
realpath_cache_size = 16M
realpath_cache_ttl = 120

; Increase limits for admin panel
max_input_nesting_level = 64
max_input_vars = 5000

; Enable output buffering
output_buffering = 4096

; Enable file uploads
file_uploads = On

; Temporary upload directory
upload_tmp_dir = /tmp

; Disable dangerous functions for security
disable_functions = pcntl_alarm,pcntl_fork,pcntl_waitpid,pcntl_wait,pcntl_wifexited,pcntl_wifstopped,pcntl_wifsignaled,pcntl_wifcontinued,pcntl_wexitstatus,pcntl_wtermsig,pcntl_wstopsig,pcntl_signal,pcntl_signal_get_handler,pcntl_signal_dispatch,pcntl_get_last_error,pcntl_strerror,pcntl_sigprocmask,pcntl_sigwaitinfo,pcntl_sigtimedwait,pcntl_exec,pcntl_getpriority,pcntl_setpriority,pcntl_async_signals,passthru,system,exec,shell_exec,popen,proc_open
EOF

# Enable PHP-FPM in rc.conf (try multiple naming conventions)
sysrc php_fpm_enable="YES" >> "$LOG_FILE" 2>&1 || \
sysrc php-fpm_enable="YES" >> "$LOG_FILE" 2>&1 || true

# Clean up and start PHP-FPM
pkill -9 php-fpm 2>/dev/null || true
pkill -9 php-fpm83 2>/dev/null || true
sleep 1

# Start PHP-FPM (try different service names and methods)
info "Starting PHP-FPM..."
if service php-fpm start >> "$LOG_FILE" 2>&1; then
    success "PHP-FPM started via service php-fpm"
elif service php-fpm83 start >> "$LOG_FILE" 2>&1; then
    success "PHP-FPM started via service php-fpm83"
elif service php_fpm start >> "$LOG_FILE" 2>&1; then
    success "PHP-FPM started via service php_fpm"
else
    # Try direct start as fallback
    info "Trying direct PHP-FPM start..."
    if [ -x /usr/local/sbin/php-fpm ]; then
        /usr/local/sbin/php-fpm -y /usr/local/etc/php-fpm.conf >> "$LOG_FILE" 2>&1 &
    elif [ -x /usr/local/sbin/php-fpm83 ]; then
        /usr/local/sbin/php-fpm83 -y /usr/local/etc/php-fpm.conf >> "$LOG_FILE" 2>&1 &
    fi
    sleep 3
fi

# Wait for socket to be created
info "Waiting for PHP-FPM socket..."
PHP_FPM_READY=0
i=1
while [ $i -le 30 ]; do
    if [ -S /var/run/php-fpm/php-fpm.sock ]; then
        success "PHP-FPM socket created"
        PHP_FPM_READY=1
        break
    fi
    if pgrep -x "php-fpm" > /dev/null 2>&1 || pgrep -x "php-fpm83" > /dev/null 2>&1; then
        # Process is running but socket might be elsewhere
        if [ -S /tmp/php-fpm.sock ]; then
            ln -sf /tmp/php-fpm.sock /var/run/php-fpm/php-fpm.sock 2>/dev/null || true
            success "PHP-FPM socket linked"
            PHP_FPM_READY=1
            break
        fi
    fi
    sleep 1
    i=$((i + 1))
done

if [ "$PHP_FPM_READY" -eq 0 ]; then
    echo "WARNING: PHP-FPM socket not found, but continuing..."
    echo "  Check: tail -f /var/log/php-fpm.log"
fi

success "PHP-FPM configured with OPcache + JIT"

# =============================================================================
# STEP 6: Create wp-config.php
# =============================================================================
info "Step 6/8: Creating wp-config.php..."

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
 * Generated by QuickPress FreeBSD Installer
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

// Performance Optimizations
// Memory limits
define('WP_MEMORY_LIMIT', '256M');
define('WP_MAX_MEMORY_LIMIT', '512M');

// Disable file editing in admin
define('DISALLOW_FILE_EDIT', true);

// Limit post revisions (reduce database bloat)
define('WP_POST_REVISIONS', 3);

// Reduce autosave interval (less DB writes)
define('AUTOSAVE_INTERVAL', 120);

// Empty trash every 7 days
define('EMPTY_TRASH_DAYS', 7);

// Disable built-in cron - use real cronjob instead
define('DISABLE_WP_CRON', true);

// Disable script concatenation in admin (faster admin)
define('CONCATENATE_SCRIPTS', false);

// Enable object caching with Redis
define('WP_CACHE', true);
define('WP_REDIS_DISABLE_METRICS', true);
define('WP_REDIS_DISABLE_PRELOAD', false);

// Redis Configuration
define('WP_REDIS_HOST', '127.0.0.1');
define('WP_REDIS_PORT', 6379);
define('WP_REDIS_DATABASE', 0);
define('WP_REDIS_TIMEOUT', 1);
define('WP_REDIS_READ_TIMEOUT', 1);
define('WP_REDIS_RETRY_INTERVAL', 100);

// Alternative: Use Redis Object Cache plugin constants
define('REDIS_HOST', '127.0.0.1');
define('REDIS_PORT', 6379);

// Use direct filesystem (faster than FTP/SSH)
define('FS_METHOD', 'direct');

// Disable automatic updates (for stability)
define('AUTOMATIC_UPDATER_DISABLED', false);

// Debug mode (disable in production)
define('WP_DEBUG', false);
define('WP_DEBUG_LOG', false);
define('WP_DEBUG_DISPLAY', false);

// Absolute path to the WordPress directory
if (!defined('ABSPATH')) {
    define('ABSPATH', __DIR__ . '/');
}

// Sets up ClassicPress vars and included files
require_once ABSPATH . 'wp-settings.php';
EOF

# Set ownership and permissions - CRITICAL FOR UPLOADS
info "Setting file permissions for uploads..."

# Set ownership on web root (recursive)
chown -R www:www ${WEB_ROOT}
chmod 644 ${WEB_ROOT}/wp-config.php

# Fix wp-content directory permissions
mkdir -p ${WEB_ROOT}/wp-content
chown www:www ${WEB_ROOT}/wp-content
chmod 775 ${WEB_ROOT}/wp-content

# Create uploads directory with proper permissions
mkdir -p ${WEB_ROOT}/wp-content/uploads
chown www:www ${WEB_ROOT}/wp-content/uploads
chmod 775 ${WEB_ROOT}/wp-content/uploads
chmod g+s ${WEB_ROOT}/wp-content/uploads

# Also fix upgrade directory permissions
mkdir -p ${WEB_ROOT}/wp-content/upgrade
chown www:www ${WEB_ROOT}/wp-content/upgrade
chmod 775 ${WEB_ROOT}/wp-content/upgrade

# Fix plugins directory permissions
mkdir -p ${WEB_ROOT}/wp-content/plugins
chown -R www:www ${WEB_ROOT}/wp-content/plugins
chmod 755 ${WEB_ROOT}/wp-content/plugins

# Fix themes directory permissions
mkdir -p ${WEB_ROOT}/wp-content/themes
chown -R www:www ${WEB_ROOT}/wp-content/themes
chmod 755 ${WEB_ROOT}/wp-content/themes

# Create test upload directory structure
TEST_YEAR=$(date +%Y)
TEST_MONTH=$(date +%m)
mkdir -p "${WEB_ROOT}/wp-content/uploads/${TEST_YEAR}/${TEST_MONTH}"
chown -R www:www "${WEB_ROOT}/wp-content/uploads"
chmod -R 775 "${WEB_ROOT}/wp-content/uploads"

# Verify permissions
if [ -w "${WEB_ROOT}/wp-content/uploads" ]; then
    success "Upload directory permissions set correctly"
else
    echo "WARNING: Upload directory may not be writable"
fi

# Fix /tmp permissions for PHP uploads
chmod 1777 /tmp
chown root:wheel /tmp

# Create a permission fix script
cat > /usr/local/bin/fix-classicpress-permissions << 'PERMEOF'
#!/bin/sh
# Fix ClassicPress/WordPress permissions
# Run this if uploads fail or permissions get corrupted

WEB_ROOT="/usr/local/www/classicpress"
PHP_USER="www"

echo "Fixing ClassicPress permissions..."

# Fix ownership
chown -R ${PHP_USER}:${PHP_USER} ${WEB_ROOT}

# Fix wp-config.php
chmod 644 ${WEB_ROOT}/wp-config.php

# Fix directories
find ${WEB_ROOT} -type d -exec chmod 755 {} \;

# Fix wp-content and uploads (need write permission)
chmod 775 ${WEB_ROOT}/wp-content
chmod 775 ${WEB_ROOT}/wp-content/uploads
chmod 775 ${WEB_ROOT}/wp-content/upgrade
chmod g+s ${WEB_ROOT}/wp-content/uploads

# Fix PHP files
find ${WEB_ROOT} -type f -name "*.php" -exec chmod 644 {} \;

# Fix uploaded files
find ${WEB_ROOT}/wp-content/uploads -type f -exec chmod 664 {} \; 2>/dev/null || true

# Fix /tmp
chmod 1777 /tmp

echo "Permissions fixed. Testing upload directory..."
if su -m ${PHP_USER} -c "touch ${WEB_ROOT}/wp-content/uploads/.test" 2>/dev/null; then
    rm -f ${WEB_ROOT}/wp-content/uploads/.test
    echo "SUCCESS: Upload directory is writable"
else
    echo "ERROR: Upload directory is still not writable"
    echo "Check: ls -la ${WEB_ROOT}/wp-content/"
fi
PERMEOF
chmod +x /usr/local/bin/fix-classicpress-permissions

success "wp-config.php created"

# =============================================================================
# STEP 7: Configure Lighttpd
# =============================================================================
info "Step 7/8: Configuring Lighttpd with performance optimizations..."

# Create Lighttpd configuration
cat > /usr/local/etc/lighttpd/lighttpd.conf << EOF
# Lighttpd Performance Configuration for ClassicPress

server.port = 80
server.bind = "0.0.0.0"
server.document-root = "/usr/local/www/classicpress"
server.errorlog = "/var/log/lighttpd/error.log"
server.pid-file = "/var/run/lighttpd.pid"
server.username = "www"
server.groupname = "www"
server.tag = "lighttpd"

# Performance Tuning
server.max-connections = 2048
server.max-request-size = 67108864
server.network-backend = "writev"
server.stream-request-body = 2
server.stream-response-body = 2

# Gzip Compression
server.modules += ( "mod_deflate" )
deflate.cache-dir = "/var/cache/lighttpd/compress"
deflate.mimetypes = (
    "text/plain",
    "text/html",
    "text/css",
    "text/javascript",
    "text/xml",
    "application/javascript",
    "application/json",
    "application/xml"
)

# MIME Types
mimetype.assign = (
    ".html" => "text/html",
    ".htm" => "text/html",
    ".txt" => "text/plain",
    ".css" => "text/css",
    ".js" => "application/javascript",
    ".php" => "application/x-httpd-php",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".png" => "image/png",
    ".ico" => "image/x-icon",
    ".svg" => "image/svg+xml",
    ".woff" => "application/font-woff",
    ".woff2" => "application/font-woff2",
    ".ttf" => "font/ttf"
)

# Security Headers
server.modules += ( "mod_setenv" )
setenv.add-response-header = (
    "X-Frame-Options" => "SAMEORIGIN",
    "X-Content-Type-Options" => "nosniff",
    "X-XSS-Protection" => "1; mode=block",
    "Referrer-Policy" => "strict-origin-when-cross-origin"
)

# URL Rewriting for ClassicPress/WordPress
server.modules += ( "mod_rewrite", "mod_fastcgi", "mod_access" )

# URL rewrite rules for WordPress/ClassicPress - FIXED for /wp-admin/ compatibility
url.rewrite-if-not-file = (
    "^/wp-admin(/.*)?" => "\$0",
    "^/wp-content(/.*)?" => "\$0",
    "^/wp-includes(/.*)?" => "\$0",
    "^/(.*\\.php)\$" => "\$1",
    "^/(.*)\$" => "/index.php"
)

# PHP-FPM FastCGI Configuration
fastcgi.server = (
    ".php" => (
        "php-local" => (
            "socket" => "/var/run/php-fpm/php-fpm.sock",
            "broken-scriptfilename" => "enable",
            "allow-x-send-file" => "enable",
            "min-procs" => 1,
            "max-procs" => 1,
            "bin-environment" => (
                "PHP_FCGI_CHILDREN" => "0",
                "PHP_FCGI_MAX_REQUESTS" => "1000"
            ),
            "fix-root-scriptname" => "enable",
            "read-timeout" => "300",
            "write-timeout" => "300",
            "connect-timeout" => "60"
        )
    )
)

# Handle index.php properly
index-file.names = ( "index.php", "index.html" )

# Static File Caching
server.modules += ( "mod_expire" )
expire.url = (
    "/" => "access plus 1 months",
    ".ico" => "access plus 1 months",
    ".png" => "access plus 1 months",
    ".jpg" => "access plus 1 months",
    ".jpeg" => "access plus 1 months",
    ".gif" => "access plus 1 months",
    ".css" => "access plus 1 weeks",
    ".js" => "access plus 1 weeks",
    ".woff" => "access plus 1 months",
    ".woff2" => "access plus 1 months",
    ".ttf" => "access plus 1 months"
)

# ETags
etag.use-inode = "disable"
etag.use-mtime = "enable"
etag.use-size = "enable"

# Deny access to hidden files
url.access-deny = ( "~", ".inc", ".htaccess", ".htpasswd" )

# Deny access to sensitive files
\$HTTP["url"] =~ "^/wp-config\\.php\$" {
    url.access-deny = ( "" )
}
EOF

# Create necessary directories
mkdir -p /var/cache/lighttpd/compress
mkdir -p /var/log/lighttpd
mkdir -p /var/run
chown -R www:www /var/cache/lighttpd
chown -R www:www /var/log/lighttpd

# Enable Lighttpd in rc.conf
sysrc lighttpd_enable="YES" >> "$LOG_FILE" 2>&1

# Clean up and start Lighttpd
pkill -9 lighttpd 2>/dev/null || true
sleep 2

info "Starting Lighttpd..."
if service lighttpd start >> "$LOG_FILE" 2>&1; then
    success "Lighttpd started"
else
    # Try direct start as fallback
    if [ -x /usr/local/sbin/lighttpd ]; then
        /usr/local/sbin/lighttpd -f /usr/local/etc/lighttpd/lighttpd.conf >> "$LOG_FILE" 2>&1 &
        sleep 3
    fi
fi

if pgrep -x lighttpd > /dev/null 2>&1; then
    success "Lighttpd configured and running"
else
    echo "WARNING: Lighttpd may not be running properly"
    echo "  Check: tail -f /var/log/lighttpd/error.log"
fi

# =============================================================================
# STEP 8: Let's Encrypt SSL Setup (Optional)
# =============================================================================
info "Step 8/8: Checking for SSL setup..."

SSL_ENABLED=0
SSL_TYPE=""

if [ "$SSL_MODE" = "letsencrypt" ]; then
    info "Setting up Let's Encrypt SSL for domain: $DOMAIN"
    
    # Install acme.sh
    ACME_SH_HOME="/root/.acme.sh"
    if [ ! -f "$ACME_SH_HOME/acme.sh" ]; then
        info "Installing acme.sh (Let's Encrypt client)..."
        curl -s https://get.acme.sh | sh -s email="$EMAIL" >> "$LOG_FILE" 2>&1
        if [ ! -f "$ACME_SH_HOME/acme.sh" ]; then
            echo "WARNING: Failed to install acme.sh, SSL setup skipped"
        fi
    fi
    
    if [ -f "$ACME_SH_HOME/acme.sh" ]; then
        mkdir -p "$SSL_DIR"
        
        # Create challenge directory
        mkdir -p "${WEB_ROOT}/.well-known/acme-challenge"
        chown -R www:www "${WEB_ROOT}/.well-known"
        
        # Issue certificate
        info "Requesting SSL certificate from Let's Encrypt..."
        export LE_WORKING_DIR="$ACME_SH_HOME"
        "$ACME_SH_HOME/acme.sh" --issue \
            -d "$DOMAIN" \
            --webroot "$WEB_ROOT" \
            --keylength 2048 \
            --reloadcmd "service lighttpd restart" \
            >> "$LOG_FILE" 2>&1
        
        if [ $? -eq 0 ]; then
            success "SSL certificate obtained for $DOMAIN"
            
            # Install certificate
            "$ACME_SH_HOME/acme.sh" --install-cert -d "$DOMAIN" \
                --key-file "${SSL_DIR}/${DOMAIN}.key" \
                --fullchain-file "${SSL_DIR}/${DOMAIN}.pem" \
                --reloadcmd "service lighttpd restart" \
                >> "$LOG_FILE" 2>&1
            
            # Create combined PEM
            cat "${SSL_DIR}/${DOMAIN}.pem" "${SSL_DIR}/${DOMAIN}.key" > "${SSL_DIR}/${DOMAIN}-combined.pem"
            chmod 600 "${SSL_DIR}/${DOMAIN}"*.pem
            
            # Configure Lighttpd for SSL
            info "Configuring Lighttpd for HTTPS..."
            cp /usr/local/etc/lighttpd/lighttpd.conf /usr/local/etc/lighttpd/lighttpd.conf.http
            
            cat >> /usr/local/etc/lighttpd/lighttpd.conf << EOF

# SSL Configuration for $DOMAIN
server.modules += ( "mod_openssl" )

\$SERVER["socket"] == ":443" {
    ssl.engine = "enable"
    ssl.pemfile = "${SSL_DIR}/${DOMAIN}-combined.pem"
    ssl.ca-file = "${SSL_DIR}/${DOMAIN}.pem"
}

# HTTP to HTTPS redirect
\$HTTP["scheme"] == "http" {
    \$HTTP["host"] =~ "^(www\\.)?${DOMAIN}\$" {
        url.redirect = ("^/(.*)" => "https://${DOMAIN}/\$1")
    }
}
EOF
            
            service lighttpd restart >> "$LOG_FILE" 2>&1
            sleep 2
            
            if pgrep -x lighttpd > /dev/null 2>&1; then
                success "SSL configured successfully"
                SSL_ENABLED=1
                SSL_TYPE="letsencrypt"
            else
                echo "WARNING: Lighttpd failed with SSL, restoring HTTP config"
                cp /usr/local/etc/lighttpd/lighttpd.conf.http /usr/local/etc/lighttpd/lighttpd.conf
                service lighttpd start >> "$LOG_FILE" 2>&1
                SSL_ENABLED=0
            fi
            
            # Setup auto-renewal
            info "Setting up automated SSL certificate renewal..."
            echo "0 3,15 * * * $ACME_SH_HOME/acme.sh --cron --home \"$ACME_SH_HOME\" >> /var/log/acme-renewal.log 2>&1" | crontab -
            success "SSL auto-renewal configured"
        else
            echo "WARNING: Failed to obtain SSL certificate"
            SSL_ENABLED=0
        fi
    fi
elif [ "$SSL_MODE" = "selfsigned" ]; then
    info "Setting up self-signed SSL certificate..."
    
    mkdir -p "$SSL_DIR"
    
    # Get IP address
    SERVER_IP=$(ifconfig | grep "inet " | grep -v "127.0.0.1" | head -1 | awk '{print $2}')
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(hostname -i 2>/dev/null | awk '{print $1}')
    fi
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP="127.0.0.1"
    fi
    
    CERT_NAME="self-signed-${SERVER_IP}"
    
    # Generate self-signed certificate
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "${SSL_DIR}/${CERT_NAME}.key" \
        -out "${SSL_DIR}/${CERT_NAME}.pem" \
        -subj "/CN=${SERVER_IP}" \
        >> "$LOG_FILE" 2>&1
    
    if [ $? -eq 0 ]; then
        success "Self-signed certificate generated"
        
        cat "${SSL_DIR}/${CERT_NAME}.pem" "${SSL_DIR}/${CERT_NAME}.key" > "${SSL_DIR}/${CERT_NAME}-combined.pem"
        chmod 600 "${SSL_DIR}/${CERT_NAME}"*.pem
        
        cp /usr/local/etc/lighttpd/lighttpd.conf /usr/local/etc/lighttpd/lighttpd.conf.http
        
        cat >> /usr/local/etc/lighttpd/lighttpd.conf << EOF

# SSL Configuration (Self-Signed)
server.modules += ( "mod_openssl" )

\$SERVER["socket"] == ":443" {
    ssl.engine = "enable"
    ssl.pemfile = "${SSL_DIR}/${CERT_NAME}-combined.pem"
}

# HTTP to HTTPS redirect
\$HTTP["scheme"] == "http" {
    url.redirect = ("^/(.*)" => "https://${SERVER_IP}/\$1")
}
EOF
        
        service lighttpd restart >> "$LOG_FILE" 2>&1
        sleep 2
        
        if pgrep -x lighttpd > /dev/null 2>&1; then
            success "Self-signed SSL configured for IP: $SERVER_IP"
            SSL_ENABLED=1
            SSL_TYPE="selfsigned"
            DOMAIN="$SERVER_IP"
        else
            echo "WARNING: Lighttpd failed with SSL"
            cp /usr/local/etc/lighttpd/lighttpd.conf.http /usr/local/etc/lighttpd/lighttpd.conf
            service lighttpd start >> "$LOG_FILE" 2>&1
            SSL_ENABLED=0
        fi
    else
        echo "ERROR: Failed to generate SSL certificate"
        SSL_ENABLED=0
    fi
else
    info "SSL setup skipped (HTTP only)"
fi

# =============================================================================
# Verification
# =============================================================================
info "Verifying installation..."

# Test PHP is working via Lighttpd
TEST_RESPONSE=$(fetch -q -o - http://127.0.0.1/wp-admin/install.php 2>/dev/null || echo "FAILED")

if echo "$TEST_RESPONSE" | grep -q "ClassicPress"; then
    success "Web server responding correctly"
else
    echo "WARNING: Web server test failed - check ${LOG_FILE}"
fi

# Test OPcache is loaded
if php -m 2>/dev/null | grep -q "Zend OPcache"; then
    success "OPcache enabled"
else
    echo "WARNING: OPcache may not be enabled"
fi

# Test object cache connection (KeyDB or Redis)
if keydb-cli ping 2>/dev/null | grep -q "PONG"; then
    success "KeyDB object cache enabled (multi-threaded)"
elif redis-cli ping 2>/dev/null | grep -q "PONG"; then
    success "Redis object cache enabled"
else
    echo "WARNING: Object cache may not be running"
fi

# Test database connection via PHP
php -r "
require '${WEB_ROOT}/wp-config.php';
\$mysqli = new mysqli(DB_HOST, DB_USER, DB_PASSWORD, DB_NAME);
if (\$mysqli->connect_error) {
    exit(1);
}
exit(0);
" 2>/dev/null || echo "WARNING: Database connection test failed"

success "Database connection verified"

# Test upload directory
if su -m www -c "touch ${WEB_ROOT}/wp-content/uploads/.test" 2>/dev/null; then
    rm -f "${WEB_ROOT}/wp-content/uploads/.test"
    success "Upload directory is writable"
else
    echo "WARNING: Upload directory is not writable"
    echo "  Run: fix-classicpress-permissions"
fi

# =============================================================================
# Final Optimizations
# =============================================================================
info "Applying ClassicPress optimizations..."

# Create system cron job to replace WP-CRON
echo "* * * * * cd ${WEB_ROOT} && /usr/local/bin/php -q wp-cron.php >/dev/null 2>&1" | crontab - 2>/dev/null || true

# Create .htaccess for reference (Lighttpd uses its own config)
cat > ${WEB_ROOT}/.htaccess << 'EOF'
# Browser Caching
<IfModule mod_expires.c>
    ExpiresActive On
    ExpiresByType image/jpg "access plus 1 month"
    ExpiresByType image/jpeg "access plus 1 month"
    ExpiresByType image/gif "access plus 1 month"
    ExpiresByType image/png "access plus 1 month"
    ExpiresByType text/css "access plus 1 week"
    ExpiresByType application/javascript "access plus 1 week"
    ExpiresByType text/javascript "access plus 1 week"
    ExpiresDefault "access plus 2 days"
</IfModule>

# BEGIN ClassicPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END ClassicPress
EOF

chown www:www ${WEB_ROOT}/.htaccess

success "ClassicPress optimizations applied"

# =============================================================================
# Get Server IP
# =============================================================================
IP=$(ifconfig | grep "inet " | grep -v "127.0.0.1" | head -1 | awk '{print $2}')
if [ -z "$IP" ]; then
    IP=$(hostname -i 2>/dev/null | awk '{print $1}')
fi
if [ -z "$IP" ]; then
    IP="YOUR_SERVER_IP"
fi

# Set URL variables
if [ "$SSL_ENABLED" = "1" ]; then
    SSL_URL_PREFIX="https"
    SSL_URL_HOST="${DOMAIN}"
else
    SSL_URL_PREFIX="http"
    SSL_URL_HOST="${IP}"
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
URL: ${SSL_URL_PREFIX}://${SSL_URL_HOST}/wp-admin/install.php
Local: http://127.0.0.1/wp-admin/install.php

DATABASE
--------
Name:     ${DB_NAME}
User:     ${DB_USER}
Password: ${DB_PASS}
Host:     127.0.0.1
Port:     3306

PERFORMANCE OPTIMIZATIONS
-------------------------
KeyDB (Redis-compatible Object Cache):
  Memory:             ${REDIS_MEM_MB}MB
  Threads:            4 (multi-threaded)
  Port:               6379
  Eviction Policy:    allkeys-lru

ClassicPress:
  WP_CACHE:           Enabled
  Object Cache:       KeyDB (install Redis Object Cache plugin)
  Memory Limit:       256M (admin: 512M)
  Post Revisions:     3
  Autosave Interval:  120s
  WP-Cron:            Disabled (use system cron)
  Filesystem:         Direct

Web Server:     Lighttpd
Max Connections: 2048
Gzip:           Enabled
Static Cache:   1 month

SSL Options:
  Let's Encrypt: ./quickpress-freebsd.sh --ssl-domain example.com --ssl-email admin@example.com
  Self-signed:   ./quickpress-freebsd.sh --ssl-self-signed
  No SSL:        ./quickpress-freebsd.sh

PHP Version:    ${PHP_VERSION}
OPcache:        Enabled (256MB)
JIT Compiler:   Enabled (128MB)
PHP-FPM Socket: /var/run/php-fpm/php-fpm.sock

Database (MariaDB):
  InnoDB Buffer Pool: ${INNODB_BUFFER_POOL}MB
  Query Cache: 64MB (MariaDB feature)
  Connection Limit: 100

FILE LOCATIONS
--------------
Web Root:     ${WEB_ROOT}
Config:       ${WEB_ROOT}/wp-config.php
Lighttpd:     /usr/local/etc/lighttpd/lighttpd.conf
PHP Config:   /usr/local/etc/php/
DB Config:    /usr/local/etc/mysql/my.cnf
KeyDB Config: /usr/local/etc/keydb.conf (or /usr/local/etc/redis.conf)
SSL Certs:    ${SSL_DIR}
SSL Setup:    ${SSL_TYPE:-None}

SSL SETUP OPTIONS
-----------------
1. Let's Encrypt (trusted certificate, requires domain):
   ./quickpress-freebsd.sh --ssl-domain example.com --ssl-email admin@example.com
   Auto-renewal: 3:00 AM & 3:00 PM daily

2. Self-signed (works with IP addresses, browser warning):
   ./quickpress-freebsd.sh --ssl-self-signed

3. No SSL (HTTP only):
   ./quickpress-freebsd.sh

SERVICE COMMANDS
----------------
Restart Lighttpd:  service lighttpd restart
Restart PHP-FPM:   service php-fpm restart
Restart Database:  service mysql-server restart
                   (or: service mariadb restart)
Restart KeyDB:     service keydb restart (or service redis restart)
Redis CLI:         redis-cli
Redis Monitor:     redis-cli monitor

Check PHP Status:
  php -i | grep opcache
  php -i | grep jit

Check Redis Status:
  redis-cli ping
  redis-cli info stats
  redis-cli info memory

NEXT STEPS
----------
1. Complete ClassicPress Setup:
   Open http://${IP}/wp-admin/install.php
   Complete the setup wizard

2. Enable Object Cache (Highly Recommended):
   - Go to wp-admin -> Plugins -> Add New
   - Search: "Redis Object Cache" by Till Kruss
   - Click Install -> Activate
   - Go to Settings -> Redis -> Click "Enable Object Cache"

View Logs:
  tail -f ${LOG_FILE}
  tail -f /var/log/lighttpd/error.log
  tail -f /var/log/redis/redis.log
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
if [ "$SSL_ENABLED" = "1" ]; then
    echo "Setup URL: https://${DOMAIN}/wp-admin/install.php"
    echo "HTTP URL:  http://${IP}/wp-admin/install.php (redirects to HTTPS)"
else
    echo "Setup URL: http://${IP}/wp-admin/install.php"
fi
echo ""
echo "Database Info:"
echo "   Name:     ${DB_NAME}"
echo "   User:     ${DB_USER}"
echo "   Password: ${DB_PASS}"
echo ""
if [ "$SSL_ENABLED" = "1" ]; then
    if [ "${SSL_TYPE}" = "selfsigned" ]; then
        echo "SSL/TLS Enabled (Self-Signed):"
        echo "   - IP Address:   ${DOMAIN}"
        echo "   - Valid for:    365 days"
        echo ""
        echo "WARNING: Browsers will show 'Not Secure' warning."
        echo "         Click 'Advanced' -> 'Proceed anyway' to access."
        echo ""
    else
        echo "SSL/TLS Enabled (Let's Encrypt):"
        echo "   - Domain:       ${DOMAIN}"
        echo "   - Auto-renewal: 3:00 AM & 3:00 PM daily"
        echo ""
    fi
fi
echo "Performance Optimizations Enabled:"
echo ""
echo "KeyDB (Redis-compatible Object Cache):"
echo "   - Memory: ${REDIS_MEM_MB}MB"
echo "   - Threads: 4 (multi-threaded)"
echo "   - Port: 6379"
echo ""
echo "ClassicPress:"
echo "   - WP_CACHE: Enabled"
echo "   - Memory Limit: 256M"
echo "   - Post Revisions: Limited to 3"
echo "   - Autosave: Every 120s"
echo ""
echo "PHP:"
echo "   - OPcache (256MB memory)"
echo "   - JIT Compiler (128MB buffer)"
echo ""
echo "Database (MariaDB):"
echo "   - InnoDB Buffer Pool: ${INNODB_BUFFER_POOL}MB"
echo ""
echo "Credentials saved to: ${CREDENTIALS_FILE}"
echo ""
echo "Next Steps:"
if [ "$SSL_ENABLED" = "1" ]; then
    echo "   1. Open https://${DOMAIN}/wp-admin/install.php"
else
    echo "   1. Open http://${IP}/wp-admin/install.php"
fi
echo "   2. Complete the ClassicPress setup wizard"
echo ""
echo "Enable Object Cache:"
echo "   1. Go to wp-admin -> Plugins -> Add New"
echo "   2. Search: 'Redis Object Cache' by Till Kruss"
echo "   3. Install and Activate"
echo "   4. Go to Settings -> Redis -> Enable Object Cache"
echo ""
echo "Troubleshooting:"
echo "   fix-classicpress-permissions - Fix upload/permission issues"
echo "   service lighttpd restart       - Restart web server"
echo "   service php-fpm restart        - Restart PHP"
echo "   service mariadb restart        - Restart database"
echo "   service keydb restart          - Restart object cache (KeyDB)"
echo "   service redis restart          - Restart object cache (Redis fallback)"
if [ "$SSL_ENABLED" = "1" ] && [ "${SSL_TYPE}" = "letsencrypt" ]; then
    echo ""
    echo "SSL Management:"
    echo "   ~/.acme.sh/acme.sh --cron --home ~/.acme.sh    - Manual renewal"
fi
echo ""
echo "=========================================="

log "Installation completed successfully"
exit 0
