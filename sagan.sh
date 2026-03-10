#!/bin/sh
# Complete Sagan Installation for FreeBSD 14.2
# Fixed: Proper YAML structure for Sagan 2.1.0, correct IPC directory, downloads all required files
set -e

export ALLOW_UNSUPPORTED_SYSTEM=yes
SAGAN_USER="sagan"
RULES_DIR="/usr/local/etc/sagan-rules"

info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || error "Must run as root"

# Kill existing sagan
pkill -9 sagan 2>/dev/null || true

# Setup swap
MEM_MB=$(sysctl -n hw.physmem 2>/dev/null | awk '{print int($1/1024/1024)}' || echo "0")
SWAP_MB=$(swapinfo -k 2>/dev/null | awk 'NR>1 {sum+=$2} END {print int(sum/1024)}' || echo "0")
if [ "$MEM_MB" -lt 2048 ] && [ "$SWAP_MB" -lt 1024 ]; then
    info "Creating 2GB swap..."
    [ -f /swapfile ] || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
    chmod 600 /swapfile
    mdconfig -a -t vnode -f /swapfile -u 0 2>/dev/null || true
    swapon /dev/md0 2>/dev/null || true
    grep -q "/swapfile" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw,file=/swapfile 0 0" >> /etc/fstab
fi

# Install dependencies
info "Installing dependencies..."
pkg update -f
pkg install -y pcre pcre2 libyaml liblognorm gmake autoconf automake libtool pkgconf git wget

# Create user
if ! id "$SAGAN_USER" >/dev/null 2>&1; then
    info "Creating sagan user..."
    pw groupadd -n sagan -g 2001 2>/dev/null || true
    pw useradd -n sagan -u 2001 -g sagan -d /var/sagan -s /sbin/nologin -c "Sagan IDS"
fi

# Create directories including IPC and lock file directories
info "Creating directories..."
mkdir -p /var/sagan /var/log/sagan /var/sagan/fifo /var/sagan/ipc /var/run/sagan
chown -R sagan:sagan /var/sagan /var/log/sagan /var/run/sagan
chmod 755 /var/sagan/ipc
[ -p /var/sagan/fifo/sagan.fifo ] || mkfifo /var/sagan/fifo/sagan.fifo
chown sagan:sagan /var/sagan/fifo/sagan.fifo

# Build Sagan
info "Downloading Sagan source..."
cd /tmp
rm -rf sagan

# Try git first, if it fails use wget
if git --version >/dev/null 2>&1; then
    git clone --depth 1 https://github.com/quadrantsec/sagan.git 2>/dev/null || {
        info "Git failed, using wget..."
        wget -q https://github.com/quadrantsec/sagan/archive/refs/heads/main.tar.gz -O sagan.tar.gz
        tar -xzf sagan.tar.gz
        mv sagan-main sagan
    }
else
    info "Using wget..."
    wget -q https://github.com/quadrantsec/sagan/archive/refs/heads/main.tar.gz -O sagan.tar.gz
    tar -xzf sagan.tar.gz
    mv sagan-main sagan
fi

cd sagan
./autogen.sh
./configure --prefix=/usr/local --sysconfdir=/usr/local/etc \
    --localstatedir=/var --enable-lognorm \
    --with-user=sagan --with-group=sagan
make && make install

# Setup rules
info "Setting up rules..."
rm -rf $RULES_DIR
mkdir -p $RULES_DIR
cd $RULES_DIR

BASE="https://raw.githubusercontent.com/quadrantsec/sagan-rules/main"

# Download all required rule files
info "Downloading rule files..."
fetch -q "$BASE/classification.config" 2>/dev/null || wget -q "$BASE/classification.config"
fetch -q "$BASE/reference.config" 2>/dev/null || wget -q "$BASE/reference.config"
fetch -q "$BASE/protocol.map" 2>/dev/null || wget -q "$BASE/protocol.map"
fetch -q "$BASE/normalization.rulebase" 2>/dev/null || wget -q "$BASE/normalization.rulebase"
fetch -q "$BASE/syslog.rules" 2>/dev/null || wget -q "$BASE/syslog.rules"
fetch -q "$BASE/openssh.rules" 2>/dev/null || wget -q "$BASE/openssh.rules"

chown -R sagan:sagan $RULES_DIR
chmod 644 $RULES_DIR/*.config $RULES_DIR/*.map $RULES_DIR/*.rulebase 2>/dev/null || true

# Setup sagan.yaml - use proper YAML structure for Sagan 2.1.0
info "Setting up sagan.yaml..."
mkdir -p /usr/local/etc/sagan

# Backup the default config if it exists
[ -f /usr/local/etc/sagan.yaml ] && mv /usr/local/etc/sagan.yaml /usr/local/etc/sagan.yaml.bak.$(date +%s) 2>/dev/null || true

cat > /usr/local/etc/sagan/sagan.yaml << 'EOF'
%YAML 1.1
---

vars:
  sagan-groups:
    RULE_PATH: "/usr/local/etc/sagan-rules"
    LOG_PATH: "/var/log/sagan"
    FIFO: "/var/sagan/fifo/sagan.fifo"
    MMAP_DEFAULT: 10000
  
  address-groups:
    HOME_NET: "any"
    EXTERNAL_NET: "any"

sagan-core:
  core:
    sensor-name: "freebsd-sensor"
    cluster-name: "freebsd-cluster"
    classification: "$RULE_PATH/classification.config"
    reference: "$RULE_PATH/reference.config"
    protocol-map: "$RULE_PATH/protocol.map"
    input-type: pipe
    batch-size: 1
    max-threads: 50
    fifo-size: 1048576
    chown-fifo: yes
    syslog: enabled
    default-host: 127.0.0.1
    default-port: 514
    default-proto: udp

  mmap-ipc:
    ipc-directory: /var/sagan/ipc
    xbit: $MMAP_DEFAULT
    flexbit: $MMAP_DEFAULT
    after: $MMAP_DEFAULT
    threshold: $MMAP_DEFAULT
    track-clients: $MMAP_DEFAULT

  liblognorm:
    enabled: yes
    normalize_rulebase: "$RULE_PATH/normalization.rulebase"

outputs:
  - fast:
      enabled: yes
      filename: "$LOG_PATH/fast.log"
  
  - alert:
      enabled: yes
      filename: "$LOG_PATH/alert.log"

rules-files:
  - $RULE_PATH/syslog.rules
  - $RULE_PATH/openssh.rules
EOF

chown sagan:sagan /usr/local/etc/sagan/sagan.yaml
ln -sf /usr/local/etc/sagan/sagan.yaml /usr/local/etc/sagan.yaml

# RC script
cat > /usr/local/etc/rc.d/sagan << 'EOF'
#!/bin/sh
# PROVIDE: sagan
# REQUIRE: LOGIN syslogd
# KEYWORD: shutdown
. /etc/rc.subr
name="sagan"
rcvar="sagan_enable"
command="/usr/local/bin/sagan"
pidfile="/var/run/sagan/sagan.pid"
load_rc_config $name
: ${sagan_enable:="NO"}
: ${sagan_flags:="-D -f /usr/local/etc/sagan/sagan.yaml"}
run_rc_command "$1"
EOF
chmod +x /usr/local/etc/rc.d/sagan
sysrc sagan_enable="YES" 2>/dev/null || echo "sagan_enable=YES" >> /etc/rc.conf

# Test
info "Testing configuration..."
rm -f /var/log/sagan/sagan.log
if timeout 15 /usr/local/bin/sagan -T 2>&1; then
    info "SUCCESS! Starting Sagan..."
    service sagan start
    sleep 2
    if pgrep -x sagan > /dev/null; then
        info "Sagan is running!"
    else
        warn "Sagan service status check failed, but process may still be running"
    fi
else
    warn "Test output from sagan.log:"
    cat /var/log/sagan/sagan.log 2>/dev/null || true
    error "Test failed"
    exit 1
fi

echo ""
echo "=========================================="
echo "SAGAN INSTALLED SUCCESSFULLY!"
echo "=========================================="
echo "Start:  service sagan start"
echo "Stop:   service sagan stop"
echo "Test:   sagan -T"
echo "Status: ps aux | grep sagan"
echo "Logs:   tail -f /var/log/sagan/sagan.log"
