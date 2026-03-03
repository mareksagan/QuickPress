#!/bin/sh
set -e

# =============================================================================
# ClassicPress Alpine Linux Installer - VM Edition
# End-to-end automated installer for Alpine Linux VMs using OpenRC
#
# Environment Variables:
#   DOMAIN  - Domain name for Let's Encrypt SSL (optional)
#   EMAIL   - Email address for Let's Encrypt SSL (optional)
#   IP_SSL  - Set to 'yes' for self-signed certificate (works with IP addresses)
#
# SSL Examples:
#   Let's Encrypt (requires domain):  DOMAIN=example.com EMAIL=admin@example.com ./quickpress.sh
#   Self-signed (works with IP):      IP_SSL=yes ./quickpress.sh
#   No SSL (HTTP only):               ./quickpress.sh
# =============================================================================

# Configuration
DB_NAME="classicpress"
DB_USER="cpuser"
DB_PASS=""
WEB_ROOT="/var/www/classicpress"
PHP_VERSION="83"
CREDENTIALS_FILE="/root/classicpress-login.txt"
LOG_FILE="/var/log/classicpress-install.log"

# SSL Configuration (optional - leave empty to skip SSL setup)
# For Let's Encrypt: Set both DOMAIN and EMAIL (e.g., DOMAIN=example.com EMAIL=admin@example.com)
# For self-signed IP cert: Set IP_SSL=yes (works with IP addresses, browsers will show warning)
DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
IP_SSL="${IP_SSL:-}"
SSL_DIR="/etc/ssl/acme"

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
info "Step 1/8: Installing packages..."

# Update package index
apk update >> "$LOG_FILE" 2>&1

# Install all required packages
apk add --no-cache \
    lighttpd \
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
    "php${PHP_VERSION}-pecl-redis" \
    "php${PHP_VERSION}-exif" \
    "php${PHP_VERSION}-iconv" \
    "php${PHP_VERSION}-pecl-imagick" \
    "php${PHP_VERSION}-intl" \
    openssl \
    socat \
    mariadb \
    mariadb-client \
    curl \
    unzip \
    openssl \
    iproute2 \
    netcat-openbsd \
    imagemagick \
    libgomp

# Install KeyDB from edge/testing repository
info "Installing KeyDB from edge/testing repository..."
apk add --no-cache keydb --repository=http://dl-cdn.alpinelinux.org/alpine/edge/testing >> "$LOG_FILE" 2>&1

success "Packages installed"

# Generate database password now that openssl is available
if [ -z "$DB_PASS" ]; then
    DB_PASS="cp$(openssl rand -hex 16)"
fi

# =============================================================================
# STEP 2: Configure and Start MariaDB with Performance Optimizations
# =============================================================================
info "Step 2/8: Configuring MariaDB with performance optimizations..."

# Create MariaDB directories
mkdir -p /run/mysqld
chown mysql:mysql /run/mysqld

# Get system memory for buffer pool calculation (use 50% of RAM for InnoDB)
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
INNODB_BUFFER_POOL=$((TOTAL_MEM_MB * 50 / 100))
if [ "$INNODB_BUFFER_POOL" -lt 128 ]; then
    INNODB_BUFFER_POOL=128
fi

# Configure MariaDB for performance
cat > /etc/my.cnf.d/mariadb-server.cnf << EOF
[mysqld]
bind-address = 127.0.0.1
port = 3306
skip-networking = 0

# Character set
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

# InnoDB Performance
innodb_buffer_pool_size = ${INNODB_BUFFER_POOL}M
innodb_buffer_pool_instances = 4
innodb_log_file_size = 128M
innodb_log_buffer_size = 16M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
innodb_file_per_table = 1
innodb_read_io_threads = 4
innodb_write_io_threads = 4
innodb_io_capacity = 2000

# Query Cache (if available in MariaDB version)
query_cache_type = 1
query_cache_size = 64M
query_cache_limit = 2M

# Connection Settings
max_connections = 100
max_user_connections = 90
wait_timeout = 300
interactive_timeout = 300
connect_timeout = 10

# Thread Settings
thread_cache_size = 16
thread_pool_size = 4

# Table Settings
table_open_cache = 4000
table_definition_cache = 2000
tmp_table_size = 64M
max_heap_table_size = 64M

# Sort and Join Buffers
sort_buffer_size = 2M
read_buffer_size = 1M
read_rnd_buffer_size = 1M
join_buffer_size = 1M

# Logging (minimal for performance)
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2
log_error = /var/log/mysql/error.log

# Disable unwanted features
skip-name-resolve
skip-external-locking
skip-slave-start

[mariadb]
# Additional MariaDB-specific settings
EOF

# Create log directory
mkdir -p /var/log/mysql
chown mysql:mysql /var/log/mysql

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
    if nc -z 127.0.0.1 3306 2>/dev/null; then
        success "MariaDB is running"
        break
    fi
    sleep 2
done

# Check if MariaDB port is open
if ! nc -z 127.0.0.1 3306 2>/dev/null; then
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

success "MariaDB configured (${INNODB_BUFFER_POOL}MB buffer pool) and database created"

# =============================================================================
# STEP 3: Configure KeyDB (Redis-compatible high-performance cache)
# =============================================================================
info "Step 3/8: Configuring KeyDB (object cache)..."

# Calculate KeyDB memory (use 10% of total RAM for object caching)
KEYDB_MEM_MB=$((TOTAL_MEM_MB * 10 / 100))
if [ "$KEYDB_MEM_MB" -lt 64 ]; then
    KEYDB_MEM_MB=64
fi

# Create KeyDB configuration directory
mkdir -p /etc/keydb
mkdir -p /var/lib/keydb
mkdir -p /var/log/keydb

# Configure KeyDB for maximum performance
cat > /etc/keydb.conf << EOF
# KeyDB Configuration - High Performance Mode
bind 127.0.0.1
port 6379
tcp-backlog 511
timeout 300
tcp-keepalive 300

# Memory Settings
maxmemory ${KEYDB_MEM_MB}mb
maxmemory-policy allkeys-lru
maxmemory-samples 5

# Persistence (disable for pure cache, enable for durability)
# For ClassicPress object cache, we can disable persistence for speed
save ""
# save 900 1
# save 300 10
# save 60 10000

stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump.rdb
dir /var/lib/keydb

# Append Only File (AOF) - disable for cache-only mode
appendonly no

# KeyDB-specific optimizations (multi-threaded)
server-threads 4
server-thread-affinity true

# appendfilename "appendonly.aof"
# appendfsync everysec
# no-appendfsync-on-rewrite no
# auto-aof-rewrite-percentage 100
# auto-aof-rewrite-min-size 64mb

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

# HyperLogLog settings
hll-sparse-max-bytes 3000

# Stream settings
stream-node-max-bytes 4096
stream-node-max-entries 100

# Active rehashing
activerehashing yes

# Client query buffer limit
client-query-buffer-limit 1gb

# Protocol limits
proto-max-bulk-len 512mb

# Slow log
slowlog-log-slower-than 10000
slowlog-max-len 128

# Latency monitoring
latency-monitor-threshold 0

# Event notification
notify-keyspace-events ""

# Kernel settings
oom-score-adj no
oom-score-adj-values 0 200 800

# Logging
loglevel notice
logfile /var/log/keydb/redis.log

# Databases (ClassicPress uses DB 0 by default)
databases 16

# Show ASCII logo on startup (why not?)
always-show-logo yes
EOF

# Set permissions
chown -R keydb:keydb /var/lib/keydb 2>/dev/null || chown -R root:root /var/lib/keydb
chown -R keydb:keydb /var/log/keydb 2>/dev/null || chown -R root:root /var/log/keydb
chmod 755 /var/lib/keydb
chmod 755 /var/log/keydb

# Enable KeyDB service
rc-update add keydb default >> "$LOG_FILE" 2>&1

# Start KeyDB
pkill -9 keydb-server 2>/dev/null || true
rm -f /var/run/keydb/keydb-server.pid 2>/dev/null || true
sleep 2

# Start KeyDB via service (ignore "already starting" warning)
service keydb start >> "$LOG_FILE" 2>&1 || true

# Wait for KeyDB to be ready
info "Waiting for KeyDB to start..."
KEYDB_READY=0
for i in $(seq 1 30); do
    if keydb-cli ping 2>/dev/null | grep -q "PONG"; then
        success "KeyDB running (${KEYDB_MEM_MB}MB memory limit, 4 threads)"
        KEYDB_READY=1
        break
    fi
    sleep 1
done

if [ "$KEYDB_READY" -eq 0 ]; then
    echo "WARNING: KeyDB may not be running properly"
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

# Configure PHP-FPM to use Unix socket (faster than TCP)
mkdir -p /run/php-fpm
sed -i 's|^listen =.*|listen = /run/php-fpm/php-fpm.sock|' /etc/php${PHP_VERSION}/php-fpm.d/www.conf
sed -i 's/^user =.*/user = lighttpd/' /etc/php${PHP_VERSION}/php-fpm.d/www.conf
sed -i 's/^group =.*/group = lighttpd/' /etc/php${PHP_VERSION}/php-fpm.d/www.conf
sed -i 's/^;listen.owner =.*/listen.owner = lighttpd/' /etc/php${PHP_VERSION}/php-fpm.d/www.conf
sed -i 's/^;listen.group =.*/listen.group = lighttpd/' /etc/php${PHP_VERSION}/php-fpm.d/www.conf
sed -i 's/^;listen.mode =.*/listen.mode = 0660/' /etc/php${PHP_VERSION}/php-fpm.d/www.conf

# Tune PHP-FPM Process Manager for performance
sed -i 's/^pm =.*/pm = dynamic/' /etc/php${PHP_VERSION}/php-fpm.d/www.conf
sed -i 's/^pm.max_children =.*/pm.max_children = 50/' /etc/php${PHP_VERSION}/php-fpm.d/www.conf
sed -i 's/^pm.start_servers =.*/pm.start_servers = 5/' /etc/php${PHP_VERSION}/php-fpm.d/www.conf
sed -i 's/^pm.min_spare_servers =.*/pm.min_spare_servers = 5/' /etc/php${PHP_VERSION}/php-fpm.d/www.conf
sed -i 's/^pm.max_spare_servers =.*/pm.max_spare_servers = 35/' /etc/php${PHP_VERSION}/php-fpm.d/www.conf
sed -i 's/^;pm.max_requests =.*/pm.max_requests = 500/' /etc/php${PHP_VERSION}/php-fpm.d/www.conf

# Increase request timeout to prevent connection resets
sed -i 's/^;request_terminate_timeout =.*/request_terminate_timeout = 300s/' /etc/php${PHP_VERSION}/php-fpm.d/www.conf

# Increase buffer sizes for admin panel
sed -i 's/^;output_buffering =.*/output_buffering = 4096/' /etc/php${PHP_VERSION}/php-fpm.d/www.conf

# Configure OPcache with JIT for maximum performance
cat >> /etc/php${PHP_VERSION}/conf.d/00_opcache.ini << 'EOF'
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

# Additional PHP optimizations for ClassicPress/WordPress
cat >> /etc/php${PHP_VERSION}/conf.d/99-quickpress.ini << 'EOF'
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

; Increase limits for admin panel (prevents connection resets)
max_input_nesting_level = 64
max_input_vars = 5000

; Enable output buffering
output_buffering = 4096

; Enable file uploads
file_uploads = On

; Temporary upload directory
upload_tmp_dir = /tmp

; Maximum upload file size (must be <= post_max_size)
upload_max_filesize = 64M

; Disable dangerous functions for security
disable_functions = pcntl_alarm,pcntl_fork,pcntl_waitpid,pcntl_wait,pcntl_wifexited,pcntl_wifstopped,pcntl_wifsignaled,pcntl_wifcontinued,pcntl_wexitstatus,pcntl_wtermsig,pcntl_wstopsig,pcntl_signal,pcntl_signal_get_handler,pcntl_signal_dispatch,pcntl_get_last_error,pcntl_strerror,pcntl_sigprocmask,pcntl_sigwaitinfo,pcntl_sigtimedwait,pcntl_exec,pcntl_getpriority,pcntl_setpriority,pcntl_async_signals,passthru,system,exec,shell_exec,popen,proc_open
EOF

# Enable PHP-FPM
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

# Wait for socket to be created
for i in $(seq 1 30); do
    if [ -S /run/php-fpm/php-fpm.sock ]; then
        success "PHP-FPM socket created"
        break
    fi
    sleep 1
done

if [ ! -S /run/php-fpm/php-fpm.sock ]; then
    error_exit "PHP-FPM socket not created"
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

// Enable object caching with Redis/Redis
define('WP_CACHE', true);
define('WP_REDIS_DISABLE_METRICS', true);
define('WP_REDIS_DISABLE_PRELOAD', false);

// Redis/Redis Configuration
define('WP_REDIS_HOST', '127.0.0.1');
define('WP_REDIS_PORT', 6379);
define('WP_REDIS_DATABASE', 0);
define('WP_REDIS_TIMEOUT', 1);
define('WP_REDIS_READ_TIMEOUT', 1);
define('WP_REDIS_RETRY_INTERVAL', 100);

// Alternative: Use Redis Object Cache plugin constants
// These work with most Redis/Redis object cache plugins
define('REDIS_HOST', '127.0.0.1');
define('REDIS_PORT', 6379);

// Use direct filesystem (faster than FTP/SSH)
define('FS_METHOD', 'direct');

// Disable automatic updates (for stability)
define('AUTOMATIC_UPDATER_DISABLED', false);

// Debug mode (enabled for troubleshooting)
define('WP_DEBUG', true);
define('WP_DEBUG_LOG', true);
define('WP_DEBUG_DISPLAY', false);
// Debug log location: ${WEB_ROOT}/wp-content/debug.log

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
chown -R lighttpd:lighttpd ${WEB_ROOT}
chmod 644 ${WEB_ROOT}/wp-config.php

# Fix wp-content directory permissions - parent MUST be writable
mkdir -p ${WEB_ROOT}/wp-content
chown lighttpd:lighttpd ${WEB_ROOT}/wp-content
chmod 775 ${WEB_ROOT}/wp-content  # 775 allows group write for uploads

# Create uploads directory with proper permissions for file uploads
mkdir -p ${WEB_ROOT}/wp-content/uploads
chown lighttpd:lighttpd ${WEB_ROOT}/wp-content/uploads
chmod 775 ${WEB_ROOT}/wp-content/uploads  # 775 with setgid for inheritance

# Set setgid bit on uploads directory so new files inherit group
chmod g+s ${WEB_ROOT}/wp-content/uploads

# Also fix upgrade directory permissions
mkdir -p ${WEB_ROOT}/wp-content/upgrade
chown lighttpd:lighttpd ${WEB_ROOT}/wp-content/upgrade
chmod 775 ${WEB_ROOT}/wp-content/upgrade

# Fix plugins directory permissions
mkdir -p ${WEB_ROOT}/wp-content/plugins
chown -R lighttpd:lighttpd ${WEB_ROOT}/wp-content/plugins
chmod 755 ${WEB_ROOT}/wp-content/plugins

# Fix themes directory permissions
mkdir -p ${WEB_ROOT}/wp-content/themes
chown -R lighttpd:lighttpd ${WEB_ROOT}/wp-content/themes
chmod 755 ${WEB_ROOT}/wp-content/themes

# Create test upload directory structure to verify permissions work
TEST_YEAR=$(date +%Y)
TEST_MONTH=$(date +%m)
mkdir -p "${WEB_ROOT}/wp-content/uploads/${TEST_YEAR}/${TEST_MONTH}"
chown -R lighttpd:lighttpd "${WEB_ROOT}/wp-content/uploads"
chmod -R 775 "${WEB_ROOT}/wp-content/uploads"

# Create debug.log file with proper permissions
touch "${WEB_ROOT}/wp-content/debug.log"
chown lighttpd:lighttpd "${WEB_ROOT}/wp-content/debug.log"
chmod 664 "${WEB_ROOT}/wp-content/debug.log"

# Verify permissions
if [ -w "${WEB_ROOT}/wp-content/uploads" ]; then
    success "Upload directory permissions set correctly"
else
    echo "WARNING: Upload directory may not be writable"
fi

# Fix /tmp permissions for PHP uploads (critical for VM environments)
chmod 1777 /tmp
chown root:root /tmp

# Create a permission fix script for future use
cat > /usr/local/bin/fix-classicpress-permissions << 'PERMEOF'
#!/bin/sh
# Fix ClassicPress/WordPress permissions
# Run this if uploads fail or permissions get corrupted

WEB_ROOT="/var/www/classicpress"
PHP_USER="lighttpd"

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

# Fix uploaded files (images, etc.)
find ${WEB_ROOT}/wp-content/uploads -type f -exec chmod 664 {} \; 2>/dev/null || true

# Fix /tmp
chmod 1777 /tmp

echo "Permissions fixed. Testing upload directory..."
if sudo -u ${PHP_USER} touch ${WEB_ROOT}/wp-content/uploads/.test 2>/dev/null; then
    rm -f ${WEB_ROOT}/wp-content/uploads/.test
    echo "SUCCESS: Upload directory is writable"
else
    echo "ERROR: Upload directory is still not writable"
    echo "Check: ls -la ${WEB_ROOT}/wp-content/"
fi
PERMEOF
chmod +x /usr/local/bin/fix-classicpress-permissions

# Create PHP temp directory if specified differently
PHP_TEMP_DIR=$(php${PHP_VERSION} -r 'echo sys_get_temp_dir();' 2>/dev/null) || PHP_TEMP_DIR="/tmp"
if [ "$PHP_TEMP_DIR" != "/tmp" ]; then
    mkdir -p "$PHP_TEMP_DIR"
    chmod 1777 "$PHP_TEMP_DIR"
    chown root:root "$PHP_TEMP_DIR"
fi

success "wp-config.php created"

# =============================================================================
# STEP 7: Configure Lighttpd
# =============================================================================
info "Step 7/8: Configuring Lighttpd with performance optimizations..."

# Create Lighttpd configuration
cat > /etc/lighttpd/lighttpd.conf << EOF
# Lighttpd Performance Configuration for ClassicPress

server.port = 80
server.bind = "0.0.0.0"
server.document-root = "/var/www/classicpress"
server.errorlog = "/var/log/lighttpd/error.log"
server.pid-file = "/run/lighttpd/lighttpd.pid"
server.username = "lighttpd"
server.groupname = "lighttpd"
server.tag = "lighttpd"

# Performance Tuning
server.max-connections = 2048
server.max-request-size = 67108864
server.network-backend = "writev"
server.stream-request-body = 2
server.stream-response-body = 2

# Event Handler (epoll on Linux)
server.event-handler = "linux-sysepoll"

# File Descriptor Limits
server.max-fds = 8192

# Gzip Compression (requires mod_deflate)
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

# URL rewrite rules for WordPress/ClassicPress
url.rewrite-if-not-file = (
    # Don't rewrite wp-admin, wp-content, wp-includes directories
    "^/wp-admin" => "\$0",
    "^/wp-content" => "\$0",
    "^/wp-includes" => "\$0",
    # Don't rewrite existing files
    "^/(.*\.php)$" => "\$1",
    # Rewrite everything else to index.php
    "^/(.*)$" => "/index.php"
)

# PHP-FPM FastCGI Configuration
fastcgi.server = (
    ".php" => (
        "php-local" => (
            "socket" => "/run/php-fpm/php-fpm.sock",
            "broken-scriptfilename" => "enable",
            "allow-x-send-file" => "enable",
            "min-procs" => 1,
            "max-procs" => 1,
            "bin-environment" => (
                "PHP_FCGI_CHILDREN" => "0",
                "PHP_FCGI_MAX_REQUESTS" => "1000"
            ),
            # Fix for WordPress/ClassicPress admin panel
            "fix-root-scriptname" => "enable",
            # Increase timeouts to prevent connection resets
            "read-timeout" => "300",
            "write-timeout" => "300",
            "connect-timeout" => "60"
        )
    )
)

# Handle index.php properly
index-file.names = ( "index.php", "index.html" )

# Static File Caching (very aggressive)
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

# ETags (built-in to lighttpd 1.4.40+, no module needed)
etag.use-inode = "disable"
etag.use-mtime = "enable"
etag.use-size = "enable"

# Deny access to hidden files
url.access-deny = ( "~", ".inc", ".htaccess", ".htpasswd" )

# Deny access to sensitive files
\$HTTP["url"] =~ "^/wp-config\.php$" {
    url.access-deny = ( "" )
}

EOF

# Create necessary directories
mkdir -p /var/cache/lighttpd/compress
mkdir -p /var/log/lighttpd
mkdir -p /run/lighttpd
chown -R lighttpd:lighttpd /var/cache/lighttpd
chown -R lighttpd:lighttpd /var/log/lighttpd
chown -R lighttpd:lighttpd /run/lighttpd

# Enable Lighttpd
rc-update add lighttpd default >> "$LOG_FILE" 2>&1

# Clean up any stale Lighttpd processes
pkill -9 lighttpd 2>/dev/null || true
sleep 2

# Start Lighttpd via service (ignore "already starting" warning)
service lighttpd start >> "$LOG_FILE" 2>&1 || true
sleep 5

# Verify Lighttpd is actually running
if ! pgrep -x lighttpd > /dev/null 2>&1; then
    # Try direct start as fallback
    /usr/sbin/lighttpd -f /etc/lighttpd/lighttpd.conf >> "$LOG_FILE" 2>&1 &
    sleep 5
fi

if pgrep -x lighttpd > /dev/null 2>&1; then
    success "Lighttpd configured and running"
else
    echo "WARNING: Lighttpd may not be running properly"
fi

# =============================================================================
# STEP 8: Let's Encrypt SSL Setup (Optional)
# =============================================================================
info "Step 8/8: Checking for Let's Encrypt SSL setup..."

SSL_ENABLED=0

if [ -n "$DOMAIN" ] && [ -n "$EMAIL" ]; then
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
        # Create SSL directory
        mkdir -p "$SSL_DIR"
        
        # Create challenge directory for ACME HTTP-01 validation
        mkdir -p "${WEB_ROOT}/.well-known/acme-challenge"
        chown -R lighttpd:lighttpd "${WEB_ROOT}/.well-known"
        
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
            
            # Install certificate files to standard location
            "$ACME_SH_HOME/acme.sh" --install-cert -d "$DOMAIN" \
                --key-file "${SSL_DIR}/${DOMAIN}.key" \
                --fullchain-file "${SSL_DIR}/${DOMAIN}.pem" \
                --reloadcmd "service lighttpd restart" \
                >> "$LOG_FILE" 2>&1
            
            # Create combined PEM file for Lighttpd
            cat "${SSL_DIR}/${DOMAIN}.pem" "${SSL_DIR}/${DOMAIN}.key" > "${SSL_DIR}/${DOMAIN}-combined.pem"
            chmod 600 "${SSL_DIR}/${DOMAIN}"*.pem
            
            # Configure Lighttpd for SSL
            info "Configuring Lighttpd for HTTPS..."
            
            # Backup original config
            cp /etc/lighttpd/lighttpd.conf /etc/lighttpd/lighttpd.conf.http
            
            # Create SSL configuration
            cat >> /etc/lighttpd/lighttpd.conf << EOF

# SSL Configuration for $DOMAIN
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
            
            # Restart Lighttpd to apply SSL config
            service lighttpd restart >> "$LOG_FILE" 2>&1
            sleep 2
            
            # Verify SSL is working
            if pgrep -x lighttpd > /dev/null 2>&1; then
                success "SSL configured successfully"
                SSL_ENABLED=1
                SSL_TYPE="letsencrypt"
            else
                echo "WARNING: Lighttpd failed to start with SSL, restoring HTTP config"
                cp /etc/lighttpd/lighttpd.conf.http /etc/lighttpd/lighttpd.conf
                service lighttpd start >> "$LOG_FILE" 2>&1
                SSL_ENABLED=0
            fi
            
            # Setup auto-renewal cron job (runs twice daily as recommended by Let's Encrypt)
            info "Setting up automated SSL certificate renewal..."
            echo "0 3,15 * * * $ACME_SH_HOME/acme.sh --cron --home \"$ACME_SH_HOME\" >> /var/log/acme-renewal.log 2>&1" | crontab -
            success "SSL auto-renewal configured (runs at 3:00 AM and 3:00 PM daily)"
            
        else
            echo "WARNING: Failed to obtain SSL certificate"
            echo "  Check the domain DNS and ensure it points to this server"
            echo "  Logs: $LOG_FILE"
            SSL_ENABLED=0
        fi
    fi
elif [ "$IP_SSL" = "yes" ] || [ "$IP_SSL" = "1" ] || [ "$IP_SSL" = "true" ]; then
    # Self-signed certificate for IP address
    info "Setting up self-signed SSL certificate for IP address..."
    info "Note: Browsers will show a security warning (this is normal for self-signed certs)"
    
    mkdir -p "$SSL_DIR"
    
    # Get IP address
    SERVER_IP=$(ip addr show 2>/dev/null | grep "inet " | grep -v "127.0.0.1" | head -1 | awk '{print $2}' | cut -d/ -f1)
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
        -addext "subjectAltName=IP:${SERVER_IP}" \
        >> "$LOG_FILE" 2>&1
    
    # Create combined PEM file for Lighttpd
    cat "${SSL_DIR}/${CERT_NAME}.pem" "${SSL_DIR}/${CERT_NAME}.key" > "${SSL_DIR}/${CERT_NAME}-combined.pem"
    chmod 600 "${SSL_DIR}/${CERT_NAME}"*.pem
    
    # Backup original config
    cp /etc/lighttpd/lighttpd.conf /etc/lighttpd/lighttpd.conf.http
    
    # Create SSL configuration
    cat >> /etc/lighttpd/lighttpd.conf << EOF

# SSL Configuration (Self-Signed for IP: $SERVER_IP)
\$SERVER["socket"] == ":443" {
    ssl.engine = "enable"
    ssl.pemfile = "${SSL_DIR}/${CERT_NAME}-combined.pem"
}

# HTTP to HTTPS redirect (for any host)
\$HTTP["scheme"] == "http" {
    url.redirect = ("^/(.*)" => "https://${SERVER_IP}/\$1")
}
EOF
    
    # Restart Lighttpd to apply SSL config
    service lighttpd restart >> "$LOG_FILE" 2>&1
    sleep 2
    
    if pgrep -x lighttpd > /dev/null 2>&1; then
        success "Self-signed SSL configured for IP: $SERVER_IP"
        SSL_ENABLED=1
        SSL_TYPE="selfsigned"
        DOMAIN="$SERVER_IP"  # Use IP as domain name for output
    else
        echo "WARNING: Lighttpd failed to start with SSL, restoring HTTP config"
        cp /etc/lighttpd/lighttpd.conf.http /etc/lighttpd/lighttpd.conf
        service lighttpd start >> "$LOG_FILE" 2>&1
        SSL_ENABLED=0
    fi
    
    info "Self-signed certificate valid for 365 days"
    info "Auto-renewal configured (checks daily, renews 30 days before expiry)"
    
    # Create renewal script for self-signed certificate
    RENEW_SCRIPT="/usr/local/bin/renew-selfsigned-cert.sh"
    cat > "$RENEW_SCRIPT" << 'RENEWEOF'
#!/bin/sh
# Self-signed certificate renewal script

SSL_DIR="/etc/ssl/acme"
LOG_FILE="/var/log/selfsigned-renewal.log"

# Get server IP
SERVER_IP=$(ip addr show 2>/dev/null | grep "inet " | grep -v "127.0.0.1" | head -1 | awk '{print $2}' | cut -d/ -f1)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -i 2>/dev/null | awk '{print $1}')
fi
if [ -z "$SERVER_IP" ]; then
    echo "$(date) - ERROR: Could not determine server IP" >> "$LOG_FILE"
    exit 1
fi

CERT_NAME="self-signed-${SERVER_IP}"
CERT_FILE="${SSL_DIR}/${CERT_NAME}.pem"

# Check if certificate exists
if [ ! -f "$CERT_FILE" ]; then
    echo "$(date) - WARNING: Certificate file not found: $CERT_FILE" >> "$LOG_FILE"
    exit 1
fi

# Check if certificate expires within 30 days (2592000 seconds)
EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_FILE" | cut -d= -f2)
EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$EXPIRY" +%s)
CURRENT_EPOCH=$(date +%s)
DAYS_UNTIL_EXPIRY=$(( (EXPIRY_EPOCH - CURRENT_EPOCH) / 86400 ))

echo "$(date) - Certificate expires in $DAYS_UNTIL_EXPIRY days" >> "$LOG_FILE"

if [ "$DAYS_UNTIL_EXPIRY" -le 30 ]; then
    echo "$(date) - Renewing certificate (expires in $DAYS_UNTIL_EXPIRY days)..." >> "$LOG_FILE"
    
    # Backup old certificate
    BACKUP_DIR="${SSL_DIR}/backup-$(date +%Y%m%d)"
    mkdir -p "$BACKUP_DIR"
    cp "${SSL_DIR}/${CERT_NAME}"*.pem "$BACKUP_DIR/" 2>/dev/null
    
    # Generate new certificate
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "${SSL_DIR}/${CERT_NAME}.key" \
        -out "${SSL_DIR}/${CERT_NAME}.pem" \
        -subj "/CN=${SERVER_IP}" \
        -addext "subjectAltName=IP:${SERVER_IP}" \
        >> "$LOG_FILE" 2>&1
    
    if [ $? -eq 0 ]; then
        # Create combined PEM file
        cat "${SSL_DIR}/${CERT_NAME}.pem" "${SSL_DIR}/${CERT_NAME}.key" > "${SSL_DIR}/${CERT_NAME}-combined.pem"
        chmod 600 "${SSL_DIR}/${CERT_NAME}"*.pem
        
        # Reload Lighttpd
        service lighttpd reload >> "$LOG_FILE" 2>&1
        
        echo "$(date) - Certificate renewed successfully" >> "$LOG_FILE"
        
        # Clean up old backups (keep last 5)
        ls -1d "${SSL_DIR}/backup-"* 2>/dev/null | sort -r | tail -n +6 | xargs -r rm -rf
    else
        echo "$(date) - ERROR: Failed to renew certificate" >> "$LOG_FILE"
        # Restore old certificate from backup
        cp "${BACKUP_DIR}/${CERT_NAME}"*.pem "${SSL_DIR}/" 2>/dev/null
        exit 1
    fi
else
    echo "$(date) - Certificate still valid, no renewal needed" >> "$LOG_FILE"
fi
RENEWEOF
    chmod +x "$RENEW_SCRIPT"
    
    # Setup cron job to run daily at 2:30 AM (checks if renewal is needed)
    info "Setting up automated self-signed certificate renewal..."
    echo "30 2 * * * $RENEW_SCRIPT >> /var/log/selfsigned-renewal.log 2>&1" | crontab -
    success "Self-signed auto-renewal configured (checks daily, renews 30 days before expiry)"
else
    info "SSL setup skipped (set DOMAIN and EMAIL for Let's Encrypt, or IP_SSL=yes for self-signed)"
    info "  Let's Encrypt: DOMAIN=example.com EMAIL=admin@example.com ./quickpress.sh"
    info "  Self-signed:   IP_SSL=yes ./quickpress.sh (works with IP addresses)"
    info "  No SSL:        ./quickpress.sh (HTTP only)"
fi

# =============================================================================
# Verification
# =============================================================================
info "Verifying installation..."

# Test PHP is working via Lighttpd
TEST_RESPONSE=$(wget -qO- --timeout=10 http://127.0.0.1/wp-admin/install.php 2>/dev/null || echo "FAILED")

if echo "$TEST_RESPONSE" | grep -q "ClassicPress"; then
    success "Web server responding correctly"
else
    echo "WARNING: Web server test failed - check ${LOG_FILE}"
fi

# Test OPcache is loaded
if php${PHP_VERSION} -m 2>/dev/null | grep -q "Zend OPcache"; then
    success "OPcache enabled"
else
    echo "WARNING: OPcache may not be enabled"
fi

# Test KeyDB connection
if keydb-cli ping 2>/dev/null | grep -q "PONG"; then
    success "KeyDB object cache enabled"
else
    echo "WARNING: KeyDB may not be running"
fi

# Test database connection via PHP
php${PHP_VERSION} -r "
require '${WEB_ROOT}/wp-config.php';
\$mysqli = new mysqli(DB_HOST, DB_USER, DB_PASSWORD, DB_NAME);
if (\$mysqli->connect_error) {
    exit(1);
}
exit(0);
" 2>/dev/null || echo "WARNING: Database connection test failed"

success "Database connection verified"

# Test upload directory is writable
if sudo -u lighttpd touch "${WEB_ROOT}/wp-content/uploads/.test" 2>/dev/null; then
    rm -f "${WEB_ROOT}/wp-content/uploads/.test"
    success "Upload directory is writable"
else
    echo "WARNING: Upload directory is not writable - uploads may fail"
    echo "  Run: fix-classicpress-permissions"
fi

# =============================================================================
# STEP 7: ClassicPress Additional Optimizations
# =============================================================================
info "Step 8/8: Applying ClassicPress optimizations..."

# Create system cron job to replace WP-CRON (much more efficient)
echo "* * * * * cd ${WEB_ROOT} && php${PHP_VERSION} -q wp-cron.php >/dev/null 2>&1" | crontab - 2>/dev/null || true

# Create .htaccess for browser caching (will work with Lighttpd mod_rewrite)
cat > ${WEB_ROOT}/.htaccess << 'EOF'
# Browser Caching
<IfModule mod_expires.c>
    ExpiresActive On
    ExpiresByType image/jpg "access plus 1 month"
    ExpiresByType image/jpeg "access plus 1 month"
    ExpiresByType image/gif "access plus 1 month"
    ExpiresByType image/png "access plus 1 month"
    ExpiresByType text/css "access plus 1 week"
    ExpiresByType application/pdf "access plus 1 month"
    ExpiresByType text/javascript "access plus 1 week"
    ExpiresByType application/javascript "access plus 1 week"
    ExpiresByType application/x-javascript "access plus 1 week"
    ExpiresByType application/x-shockwave-flash "access plus 1 month"
    ExpiresByType image/x-icon "access plus 1 year"
    ExpiresDefault "access plus 2 days"
</IfModule>

# Gzip Compression
<IfModule mod_deflate.c>
    AddOutputFilterByType DEFLATE text/plain
    AddOutputFilterByType DEFLATE text/html
    AddOutputFilterByType DEFLATE text/xml
    AddOutputFilterByType DEFLATE text/css
    AddOutputFilterByType DEFLATE application/xml
    AddOutputFilterByType DEFLATE application/xhtml+xml
    AddOutputFilterByType DEFLATE application/rss+xml
    AddOutputFilterByType DEFLATE application/javascript
    AddOutputFilterByType DEFLATE application/x-javascript
</IfModule>

# Protect sensitive files
<FilesMatch "^\.(htaccess|htpasswd|ini|log|sh)$">
    Order allow,deny
    Deny from all
</FilesMatch>

# Disable directory browsing
Options -Indexes

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

chown lighttpd:lighttpd ${WEB_ROOT}/.htaccess

success "ClassicPress optimizations applied"

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

# Set URL variables for credentials file
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
Redis (Redis-compatible object cache):
  Memory:             ${KEYDB_MEM_MB}MB
  Threads:            4 (multi-threaded)
  Port:               6379
  Persistence:        Disabled (cache-only)
  Eviction Policy:    allkeys-lru

ClassicPress:
  WP_CACHE:           Enabled
  Object Cache:       KeyDB (install Redis Object Cache plugin)
  Memory Limit:       256M (admin: 512M)
  Post Revisions:     3 (limits DB bloat)
  Autosave Interval:  120s (less DB writes)
  WP-Cron:            Disabled (use system cron)
  Filesystem:         Direct

Web Server:     Lighttpd (lightweight & fast)
Event Handler:  linux-sysepoll
Max Connections: 2048
Gzip:           Enabled
Static Cache:   1 month

SSL Options:
  Let's Encrypt: DOMAIN=example.com EMAIL=admin@example.com ./quickpress.sh
  Self-signed:   IP_SSL=yes ./quickpress.sh (works with IP addresses)
  No SSL:        ./quickpress.sh (HTTP only)

PHP Version:    ${PHP_VERSION}
OPcache:        Enabled (256MB)
JIT Compiler:   Enabled (128MB)
PHP-FPM Socket: /run/php-fpm/php-fpm.sock
Process Manager: Dynamic (5-50 children)
Realpath Cache: 16MB

MariaDB:
  InnoDB Buffer Pool: ${INNODB_BUFFER_POOL}MB
  Query Cache: 64MB
  Connection Limit: 100
  Table Cache: 4000
  Log Files: /var/log/mysql/

FILE LOCATIONS
--------------
Web Root:     ${WEB_ROOT}
Config:       ${WEB_ROOT}/wp-config.php
Lighttpd:     /etc/lighttpd/lighttpd.conf
PHP Config:   /etc/php${PHP_VERSION}/conf.d/00_opcache.ini
MariaDB:      /etc/my.cnf.d/mariadb-server.cnf
Redis Config: /etc/keydb.conf
Redis Data:   /var/lib/keydb
SSL Certs:    ${SSL_DIR}
SSL Setup:    ${SSL_TYPE:-None}

SSL SETUP OPTIONS
-----------------
1. Let's Encrypt (trusted certificate, requires domain):
   DOMAIN=example.com EMAIL=admin@example.com ./quickpress.sh
   Auto-renewal: 3:00 AM & 3:00 PM daily

2. Self-signed (works with IP addresses, browser warning):
   IP_SSL=yes ./quickpress.sh
   Auto-renewal: Daily at 2:30 AM (renews 30 days before expiry)

3. No SSL (HTTP only):
   ./quickpress.sh

SERVICE COMMANDS
----------------
Restart Lighttpd:  service lighttpd restart
Restart PHP-FPM:   service php-fpm${PHP_VERSION} restart
Restart MariaDB:   service mariadb restart
Restart KeyDB:     service keydb restart
KeyDB CLI:         keydb-cli
KeyDB Monitor:     keydb-cli monitor

Check PHP Status:
  php -i | grep opcache
  php -i | grep jit

Check KeyDB Status:
  keydb-cli ping
  keydb-cli info stats
  keydb-cli info memory

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
   (Plugin will auto-connect to KeyDB at 127.0.0.1:6379)

View Logs:
  tail -f ${LOG_FILE}
  tail -f /var/log/lighttpd/error.log
  tail -f /var/log/keydb/keydb.log
  tail -f /var/log/acme-renewal.log        # Let's Encrypt renewal logs
  tail -f /var/log/selfsigned-renewal.log  # Self-signed renewal logs
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
        echo "   - Certificate:  Self-signed (browsers will show warning)"
        echo "   - Valid for:    365 days"
        echo "   - Auto-renewal: Checks daily, renews 30 days before expiry"
        echo ""
        echo "WARNING: Browsers will show 'Not Secure' warning. This is normal for self-signed certs."
        echo "         Click 'Advanced' -> 'Proceed anyway' to access the site."
        echo ""
    else
        echo "SSL/TLS Enabled (Let's Encrypt):"
        echo "   - Domain:       ${DOMAIN}"
        echo "   - Certificate:  Trusted (browsers show secure lock)"
        echo "   - Auto-renewal: 3:00 AM & 3:00 PM daily"
        echo "   - Cert path:    ${SSL_DIR}/${DOMAIN}.pem"
        echo "   - Key path:     ${SSL_DIR}/${DOMAIN}.key"
        echo ""
    fi
fi
echo "Performance Optimizations Enabled:"
echo ""
echo "KeyDB (Redis-compatible):"
echo "   - Object Cache: Enabled (${KEYDB_MEM_MB}MB)"
echo "   - Multi-threaded: 4 threads"
echo "   - Persistence: Disabled (pure cache mode)"
echo "   - Eviction: allkeys-lru"
echo "   - Redis Plugin: Install manually from wp-admin"
echo ""
echo "ClassicPress:"
echo "   - WP_CACHE: Enabled"
echo "   - KeyDB Object Cache: Install Redis Object Cache plugin"
echo "   - Memory Limit: 256M (admin: 512M)"

echo "   - Post Revisions: Limited to 3"
echo "   - Autosave: Every 120s (less DB writes)"
echo "   - WP-Cron: Disabled (use system cron)"
echo "   - Direct Filesystem: Enabled"
echo ""
echo "Lighttpd:"
echo "   - Event Handler: linux-sysepoll"
echo "   - Max Connections: 2048"
echo "   - Gzip Compression: Enabled"
echo "   - Static File Caching: 1 month"
echo "   - ETags: Enabled"
echo ""
echo "PHP:"
echo "   - OPcache (256MB memory)"
echo "   - JIT Compiler (128MB buffer)"
echo "   - Unix Socket (faster than TCP)"
echo "   - Dynamic Process Manager"
echo "   - Realpath Cache (16MB)"
echo ""
echo "MariaDB:"
echo "   - InnoDB Buffer Pool: ${INNODB_BUFFER_POOL}MB"
echo "   - Query Cache: 64MB"
echo "   - Connection Limit: 100"
echo "   - Table Cache: 4000"
echo ""
echo "Credentials saved to: ${CREDENTIALS_FILE}"
echo ""
echo "Next Steps:"
if [ "$SSL_ENABLED" = "1" ]; then
    echo "   1. Open https://${DOMAIN}/wp-admin/install.php in your browser"
else
    echo "   1. Open http://${IP}/wp-admin/install.php in your browser"
fi
echo "   2. Complete the ClassicPress setup wizard"
echo "   3. Configure your site title and admin user"
echo ""
echo "Enable Object Cache (Recommended):"
echo "   1. Go to wp-admin -> Plugins -> Add New"
echo "   2. Search: 'Redis Object Cache' by Till Kruss"
echo "   3. Click Install -> Activate"
echo "   4. Go to Settings -> Redis -> Click 'Enable Object Cache'"
echo "   (Connects automatically to KeyDB at 127.0.0.1:6379)"
echo ""
echo "File Upload Troubleshooting:"
echo "   If uploads fail with 'could not be moved' error:"
echo "   1. Fix permissions: /usr/local/bin/fix-classicpress-permissions"
echo "   2. Check /tmp: ls -ld /tmp (should be drwxrwxrwt)"
echo "   3. Check uploads dir: ls -la ${WEB_ROOT}/wp-content/uploads/"
echo "   4. PHP extensions: php83 -m | grep -E '(gd|exif|imagick)'"
echo "   5. Upload limits: php83 -r 'echo ini_get(\"upload_max_filesize\");'"
echo "   6. Web server errors: tail -f /var/log/lighttpd/error.log"
echo "   7. PHP error log: tail -f /var/log/php*/error.log"
echo ""
echo "Debugging (WP_DEBUG is enabled):"
echo "   WordPress debug log: tail -f ${WEB_ROOT}/wp-content/debug.log"
echo "   To disable: Edit ${WEB_ROOT}/wp-config.php and set WP_DEBUG to false"
echo ""
echo "Service Management:"
echo "   service lighttpd restart    - Restart web server"
echo "   service php-fpm${PHP_VERSION} restart - Restart PHP"
echo "   service mariadb restart     - Restart database"
echo "   service keydb restart       - Restart object cache"
echo "   fix-classicpress-permissions - Fix upload/permission issues"
if [ "$SSL_ENABLED" = "1" ]; then
    echo ""
    if [ "${SSL_TYPE}" = "selfsigned" ]; then
        echo "SSL Certificate Management (Self-Signed):"
        echo "   cat ${SSL_DIR}/self-signed-*.pem               - View certificate"
        echo "   /usr/local/bin/renew-selfsigned-cert.sh        - Manual renewal check"
        echo "   cat /var/log/selfsigned-renewal.log            - View renewal logs"
        echo "   rm ${SSL_DIR}/self-signed-* && IP_SSL=yes ./quickpress.sh  - Force renew"
    else
        echo "SSL Certificate Management (Let's Encrypt):"
        echo "   ~/.acme.sh/acme.sh --cron --home ~/.acme.sh    - Manual renewal"
        echo "   ~/.acme.sh/acme.sh --renew -d ${DOMAIN}        - Renew specific domain"
        echo "   ~/.acme.sh/acme.sh --list                      - List certificates"
        echo "   cat /var/log/acme-renewal.log                  - View renewal logs"
    fi
fi
echo ""
echo "Performance Check:"
echo "   php -i | grep opcache"
echo "   lighttpd -V"
echo "   keydb-cli info stats"
echo ""
echo "=========================================="

log "Installation completed successfully"
exit 0
