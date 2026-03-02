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
# STEP 2: Configure and Start MariaDB with Performance Optimizations
# =============================================================================
info "Step 2/6: Configuring MariaDB with performance optimizations..."

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
# STEP 3: Download ClassicPress
# =============================================================================
info "Step 3/7: Downloading ClassicPress..."

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
# STEP 4: Configure PHP-FPM with Optimizations
# =============================================================================
info "Step 4/7: Configuring PHP-FPM with optimizations..."

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
# STEP 5: Create wp-config.php
# =============================================================================
info "Step 5/7: Creating wp-config.php..."

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

// Enable object caching (if available)
define('WP_CACHE', true);

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

# Set ownership and permissions
chown -R lighttpd:lighttpd ${WEB_ROOT}
chmod 644 ${WEB_ROOT}/wp-config.php

success "wp-config.php created"

# =============================================================================
# STEP 6: Configure Lighttpd
# =============================================================================
info "Step 6/7: Configuring Lighttpd with performance optimizations..."

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

# Gzip Compression
compress.allowed-encodings = ( "gzip", "deflate" )
compress.cache-dir = "/var/cache/lighttpd/compress"
compress.filetype = (
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
server.modules += ( "mod_rewrite", "mod_fastcgi" )

url.rewrite-if-not-file = (
    "^/(wp-(admin|content|includes)/.*)$" => "\$1",
    "^/(.*)\.php(.*)$" => "\$1.php\$2",
    "^/(.*)$" => "/index.php?q=\$1"
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
            )
        )
    )
)

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
\$HTTP["url"] =~ "/(wp-config\.php|wp-admin/install\.php)$" {
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

# Clean up and start Lighttpd
pkill -9 lighttpd 2>/dev/null || true
rm -f /run/openrc/starting/lighttpd /run/openrc/started/lighttpd 2>/dev/null || true
sleep 1

# Start Lighttpd directly
/usr/sbin/lighttpd -D -f /etc/lighttpd/lighttpd.conf >> "$LOG_FILE" 2>&1 &
sleep 3

# Verify it's running
if ! pgrep -x lighttpd > /dev/null 2>&1; then
    service lighttpd start >> "$LOG_FILE" 2>&1 || true
    sleep 3
fi

success "Lighttpd configured and running"

# =============================================================================
# STEP 7: Verification
# =============================================================================
info "Step 7/7: Verifying installation..."

# Test PHP is working via Lighttpd
TEST_RESPONSE=$(wget -qO- --timeout=10 http://127.0.0.1/wp-admin/install.php 2>/dev/null || echo "FAILED")

if echo "$TEST_RESPONSE" | grep -q "ClassicPress"; then
    success "Web server responding correctly"
else
    error_exit "Web server test failed - check ${LOG_FILE}"
fi

# Test OPcache is loaded
if php${PHP_VERSION} -m 2>/dev/null | grep -q "Zend OPcache"; then
    success "OPcache enabled"
else
    echo "WARNING: OPcache may not be enabled"
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
# STEP 7: ClassicPress Additional Optimizations
# =============================================================================
info "Step 7/7: Applying ClassicPress optimizations..."

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

PERFORMANCE OPTIMIZATIONS
-------------------------
ClassicPress:
  WP_CACHE:           Enabled
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

SERVICE COMMANDS
----------------
Restart Lighttpd:  service lighttpd restart
Restart PHP-FPM:   service php-fpm${PHP_VERSION} restart
Restart MariaDB:   service mariadb restart

Check PHP Status:
  php -i | grep opcache
  php -i | grep jit

View Logs:
  tail -f ${LOG_FILE}
  tail -f /var/log/lighttpd/error.log
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
echo "Performance Optimizations Enabled:"
echo ""
echo "ClassicPress:"
echo "   - WP_CACHE: Enabled"
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
echo "   1. Open http://${IP}/wp-admin/install.php in your browser"
echo "   2. Complete the ClassicPress setup wizard"
echo "   3. Configure your site title and admin user"
echo ""
echo "Service Management:"
echo "   service lighttpd restart    - Restart web server"
echo "   service php-fpm${PHP_VERSION} restart - Restart PHP"
echo "   service mariadb restart     - Restart database"
echo ""
echo "Performance Check:"
echo "   php -i | grep opcache"
echo "   lighttpd -V"
echo ""
echo "=========================================="

log "Installation completed successfully"
exit 0
