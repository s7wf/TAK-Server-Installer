#!/usr/bin/env bash
# tak-install.sh — One-shot TAK Server installer (Rocky 8/9)
# - Installs Java 17, PostgreSQL 15 (reuses if present)
# - Creates DB/user, adjusts pg_hba
# - Installs TAK (monolithic or core RPM you provide)
# - Fixes CoreConfig.xml (JDBC, Admin UI, truststore)
# - Generates Root CA, admin cert, registers admin
# - Exports Windows-friendly PFX (admin-fixed.pfx) with password
# - Opens firewall ports and starts TAK

set -euo pipefail
JAVA_VER=unknown

##############################
# Config (override via env)
##############################
TAK_DB_NAME="${TAK_DB_NAME:-tak}"
TAK_DB_USER="${TAK_DB_USER:-tak}"
TAK_DB_PASS="${TAK_DB_PASS:-StrongPassHere}"       # CHANGE ME
PG_PORT="${PG_PORT:-5432}"
TAK_TLS_PORT="${TAK_TLS_PORT:-8089}"
TAK_HTTPS_PORT="${TAK_HTTPS_PORT:-8443}"
TAK_CERT_PORT="${TAK_CERT_PORT:-8446}"
PFX_PASS="${PFX_PASS:-atakatak}"

RPM_PATH=""
if [[ "${1:-}" == "--rpm" ]]; then
  RPM_PATH="${2:-}"
fi

log(){ printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err(){ printf "\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; }
die(){ err "$*"; exit 1; }

require_root(){ [[ $EUID -eq 0 ]] || die "Run as root (use sudo)."; }
check_os(){
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
  . /etc/os-release
  [[ "$ID" == "rocky" || "$ID_LIKE" =~ rhel ]] || die "Only Rocky/RHEL-like supported."
  log "Detected OS: $PRETTY_NAME"
}

trap 'err "An error occurred. Scroll up for details."' ERR
require_root
check_os

##############################
# Base deps + Java 17
##############################
log "Installing base dependencies and Java 17…"
dnf -y install epel-release >/dev/null 2>&1 || true
# Install deps one-by-one so we can report failures precisely
for pkg in java-17-openjdk java-17-openjdk-devel openssl firewalld policycoreutils-python-utils unzip curl sed gawk grep which; do
  rpm -q "$pkg" >/dev/null 2>&1 || dnf -y install "$pkg" >/dev/null
done
alternatives --set java /usr/lib/jvm/java-17-openjdk-*/bin/java >/dev/null || true
JAVA_VER="${JAVA_VER:-$(java -version 2>&1 | head -n1 || echo unknown)}"
log "Java: $JAVA_VER"

##############################
# PostgreSQL 15
##############################
if systemctl is-active --quiet postgresql-15; then
  log "PostgreSQL 15 already running."
else
  log "Installing PostgreSQL 15…"
  dnf -y install "https://download.postgresql.org/pub/repos/yum/reporpms/EL-$(rpm -E %rhel)-$(uname -m)/pgdg-redhat-repo-latest.noarch.rpm" >/dev/null
  dnf -qy module disable postgresql || true
  dnf -y install postgresql15 postgresql15-server >/dev/null
  [[ -d /var/lib/pgsql/15/data/base ]] || /usr/pgsql-15/bin/postgresql-15-setup initdb >/dev/null
  systemctl enable --now postgresql-15
fi
sleep 1
systemctl is-active --quiet postgresql-15 || { restorecon -Rv /var/lib/pgsql/15 >/dev/null || true; systemctl restart postgresql-15; }

# Ensure pg_hba has scram rule for TAK user on localhost
if ! grep -qE "^[[:space:]]*host[[:space:]]+all[[:space:]]+${TAK_DB_USER}[[:space:]]+127\.0\.0\.1/32" /var/lib/pgsql/15/data/pg_hba.conf; then
  echo "host    all    ${TAK_DB_USER}    127.0.0.1/32    scram-sha-256" >> /var/lib/pgsql/15/data/pg_hba.conf
  systemctl restart postgresql-15
fi

# Create role & DB if missing
log "Ensuring role '${TAK_DB_USER}' and DB '${TAK_DB_NAME}' exist…"
sudo -u postgres psql -p "${PG_PORT}" -tAc "SELECT 1 FROM pg_roles WHERE rolname='${TAK_DB_USER}'" | grep -q 1 || \
  sudo -u postgres psql -p "${PG_PORT}" -c "CREATE USER ${TAK_DB_USER} WITH PASSWORD '${TAK_DB_PASS}';"
sudo -u postgres psql -p "${PG_PORT}" -tAc "SELECT 1 FROM pg_database WHERE datname='${TAK_DB_NAME}'" | grep -q 1 || \
  sudo -u postgres psql -p "${PG_PORT}" -c "CREATE DATABASE ${TAK_DB_NAME} OWNER ${TAK_DB_USER};"

PGPASSWORD="${TAK_DB_PASS}" psql -h 127.0.0.1 -p "${PG_PORT}" -U "${TAK_DB_USER}" -d "${TAK_DB_NAME}" -c "select 1;" >/dev/null

##############################
# Install TAK (RPM if provided)
##############################
if [[ -n "${RPM_PATH}" ]]; then
  [[ -f "${RPM_PATH}" ]] || die "RPM not found: ${RPM_PATH}"
  log "Installing TAK RPM: ${RPM_PATH}"
  dnf -y install "${RPM_PATH}"
else
  if rpm -q takserver >/dev/null 2>&1 || rpm -q takserver-core >/dev/null 2>&1; then
    log "TAK package already installed. Skipping RPM step."
  else
    die "No TAK RPM provided and none installed. Re-run with: --rpm /path/to/takserver*.rpm"
  fi
fi
[[ -d /opt/tak ]] || die "/opt/tak missing after install."

##############################
# TLS / CA / Truststore
##############################
CERTS_DIR="/opt/tak/certs"
FILES_DIR="$CERTS_DIR/files"
install -d -o tak -g tak "$FILES_DIR"
# Root CA
if [[ ! -f "$CERTS_DIR/ca.pem" ]]; then
  log "Generating Root CA…"
  openssl genrsa -out "$CERTS_DIR/ca-do-not-share.key" 4096 >/dev/null 2>&1
  openssl req -x509 -new -nodes -key "$CERTS_DIR/ca-do-not-share.key" -sha256 -days 3650 \
    -subj "/C=US/ST=CA/L=SanDiego/O=TAK/OU=RootCA/CN=TAK Root CA" -out "$CERTS_DIR/ca.pem" >/dev/null 2>&1
fi
# Truststore (root-only)
if [[ ! -f "$FILES_DIR/truststore-root.jks" ]]; then
  keytool -importcert -alias tak-root -file "$CERTS_DIR/ca.pem" -keystore "$FILES_DIR/truststore-root.jks" -storepass atakatak -noprompt >/dev/null
fi
chown -R tak:tak "$CERTS_DIR"

##############################
# CoreConfig.xml edits
##############################
CFG="/opt/tak/CoreConfig.xml"
[[ -f "$CFG" ]] || die "CoreConfig.xml not found."
cp -a "$CFG" "${CFG}.bak.$(date +%s)"

# JDBC URL/creds
sed -i \
  -e "s|jdbc:postgresql://127\.0\.0\.1:[0-9]\+/[^\"']*|jdbc:postgresql://127.0.0.1:${PG_PORT}/${TAK_DB_NAME}|" \
  -e "s/username=\"[^\"]*\"/username=\"${TAK_DB_USER}\"/" \
  -e "s/password=\"[^\"]*\"/password=\"${TAK_DB_PASS}\"/" \
  "$CFG"

# Admin UI enabled on 8443 + clientAuth true
if grep -q '<connector port="8443"' "$CFG"; then
  sed -i 's|<connector port="8443"[^>]*/>|<connector port="8443" _name="https" enableAdminUI="true" enableWebtak="true" clientAuth="true"/>|' "$CFG"
else
  sed -i "/<\/network>/i \ \ \ \ <connector port=\"8443\" _name=\"https\" enableAdminUI=\"true\" enableWebtak=\"true\" clientAuth=\"true\"/>" "$CFG"
fi

# Point truststore to Root CA truststore
sed -i 's|truststoreFile="certs/files/[^"]*"|truststoreFile="certs/files/truststore-root.jks"|' "$CFG"

# Disable federation initially (can re-enable later)
if grep -q '<federation>' "$CFG"; then
  awk 'BEGIN{c=0} /<federation>/{c=1;print "<!-- federation disabled";next} c && /<\/federation>/{c=0;print "-->";next} !c{print}' "$CFG" > "${CFG}.new" && mv "${CFG}.new" "$CFG"
fi

##############################
# Authorize admin cert (make if missing)
##############################
# Create admin cert+key using TAK script if not present
if [[ ! -f "$FILES_DIR/admin.pem" || ! -f "$CERTS_DIR/admin.key" ]]; then
  log "Creating admin client certificate via makeCert.sh…"
  sudo -u tak bash -lc "cd $CERTS_DIR && ./makeCert.sh client admin"
fi

# Register admin with TAK
if [[ -f /opt/tak/utils/UserManager.jar ]]; then
  log "Registering admin certificate with TAK user DB…"
  java -jar /opt/tak/utils/UserManager.jar certmod -A "$FILES_DIR/admin.pem" >/dev/null
else
  warn "UserManager.jar not found; cannot auto-register admin cert."
fi

##############################
# Firewall in active zone(s)
##############################
systemctl enable --now firewalld >/dev/null 2>&1 || true
ACTIVE_ZONES=$(firewall-cmd --get-active-zones | awk 'NR==1{print}')
[[ -n "$ACTIVE_ZONES" ]] || ACTIVE_ZONES="public"
for Z in $ACTIVE_ZONES; do
  firewall-cmd --zone="$Z" --add-port=${TAK_TLS_PORT}/tcp --permanent >/dev/null 2>&1 || true
  firewall-cmd --zone="$Z" --add-port=${TAK_HTTPS_PORT}/tcp --permanent >/dev/null 2>&1 || true
  firewall-cmd --zone="$Z" --add-port=${TAK_CERT_PORT}/tcp --permanent >/dev/null 2>&1 || true
done
firewall-cmd --reload >/dev/null || true

##############################
# Start TAK
##############################
systemctl daemon-reload || true
systemctl enable --now takserver
sleep 3

##############################
# Export Windows-friendly PFX
##############################
log "Building Windows PFX for admin (includes full chain)…"
PFX_OUT="$FILES_DIR/admin-fixed.pfx"
openssl pkcs12 -export \
  -inkey "$CERTS_DIR/admin.key" \
  -in    "$FILES_DIR/admin.pem" \
  -certfile "$CERTS_DIR/ca.pem" \
  -name "TAK Admin" \
  -out "$PFX_OUT" \
  -passout pass:${PFX_PASS}

# Verify PFX quickly
if openssl pkcs12 -info -in "$PFX_OUT" -passin pass:${PFX_PASS} 2>/dev/null | grep -q "MAC verified OK"; then
  log "Admin PFX created: $PFX_OUT"
else
  warn "PFX export verification did not show 'MAC verified OK' — check inputs."
fi

##############################
# Summary
##############################
IP=$(hostname -I 2>/dev/null | awk '{print $1}'); IP=${IP:-127.0.0.1}
echo
echo "============================================================"
echo "✅ TAK install/config complete (best effort)"
echo "------------------------------------------------------------"
echo "Java:        ${JAVA_VER}"
echo "PostgreSQL:  $(psql -V 2>/dev/null | head -n1)"
echo "DB:          ${TAK_DB_NAME} (owner ${TAK_DB_USER}) on port ${PG_PORT}"
echo "Ports:       TLS ${TAK_TLS_PORT}, HTTPS ${TAK_HTTPS_PORT}, Cert ${TAK_CERT_PORT}"
echo "Truststore:  $FILES_DIR/truststore-root.jks (pass: atakatak)"
echo "Admin PFX:   $PFX_OUT"
echo "PFX pass:    ${PFX_PASS}"
echo
echo "Service:     systemctl status takserver"
echo "Logs:        /opt/tak/logs/takserver-*.log"
echo
echo "Open UI:     https://${IP}:${TAK_HTTPS_PORT}"
echo "             (Import admin-fixed.pfx on Windows; password: ${PFX_PASS})"
echo "============================================================"
