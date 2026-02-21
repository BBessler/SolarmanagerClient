#!/bin/bash
# =============================================================================
# Solarmanager - Docker Installation
# MariaDB nativ, Backend + Caddy + phpMyAdmin + Portainer in Docker
# Kann beliebig oft aufgerufen werden (idempotent)
# Unterstuetzte Distros: Debian/Ubuntu, RHEL/Fedora/CentOS, Arch, openSUSE
# =============================================================================

set -e

# =============================================================================
# Distro-Erkennung
# =============================================================================
detect_distro() {
    if [ ! -f /etc/os-release ]; then
        echo "[FEHLER] /etc/os-release nicht gefunden. Unterstuetzte Distros: Debian/Ubuntu, RHEL/Fedora/CentOS, Arch, openSUSE."
        exit 1
    fi

    . /etc/os-release

    case "$ID" in
        debian|ubuntu|raspbian|linuxmint)
            DISTRO_FAMILY="debian"
            ;;
        rhel|centos|fedora|rocky|almalinux|ol)
            DISTRO_FAMILY="rhel"
            ;;
        arch|manjaro|endeavouros)
            DISTRO_FAMILY="arch"
            ;;
        opensuse*|sles)
            DISTRO_FAMILY="suse"
            ;;
        *)
            # Fallback: ID_LIKE pruefen
            case "$ID_LIKE" in
                *debian*|*ubuntu*)
                    DISTRO_FAMILY="debian"
                    ;;
                *rhel*|*fedora*|*centos*)
                    DISTRO_FAMILY="rhel"
                    ;;
                *arch*)
                    DISTRO_FAMILY="arch"
                    ;;
                *suse*)
                    DISTRO_FAMILY="suse"
                    ;;
                *)
                    echo "[FEHLER] Unbekannte Distribution: $ID ($ID_LIKE)"
                    echo "         Unterstuetzte Distros: Debian/Ubuntu, RHEL/Fedora/CentOS, Arch, openSUSE."
                    exit 1
                    ;;
            esac
            ;;
    esac

    echo "[INFO] Erkannte Distribution: $ID ($DISTRO_FAMILY)"
}

# =============================================================================
# Paketmanager-Hilfsfunktionen
# =============================================================================
pkg_update() {
    case "$DISTRO_FAMILY" in
        debian) sudo apt-get update ;;
        rhel)   sudo dnf check-update || true ;;
        arch)   sudo pacman -Sy ;;
        suse)   sudo zypper refresh ;;
    esac
}

pkg_install() {
    case "$DISTRO_FAMILY" in
        debian) sudo apt-get install -y "$@" ;;
        rhel)   sudo dnf install -y "$@" ;;
        arch)   sudo pacman -S --noconfirm --needed "$@" ;;
        suse)   sudo zypper install -y "$@" ;;
    esac
}

pkg_installed() {
    case "$DISTRO_FAMILY" in
        debian) dpkg -s "$1" &> /dev/null ;;
        rhel)   rpm -q "$1" &> /dev/null ;;
        arch)   pacman -Qi "$1" &> /dev/null ;;
        suse)   rpm -q "$1" &> /dev/null ;;
    esac
}

# =============================================================================
# Paketnamen-Mapping
# =============================================================================
set_package_names() {
    case "$DISTRO_FAMILY" in
        debian)
            PKG_MARIADB="mariadb-server"
            PKG_AVAHI="avahi-daemon"
            PKG_APACHE="apache2"
            PKG_PHP="php libapache2-mod-php php-mysql"
            PKG_PHPMYADMIN="phpmyadmin"
            PKG_DEBCONF_UTILS="debconf-utils"
            PKG_CURL="curl"
            APACHE_SERVICE="apache2"
            ;;
        rhel)
            PKG_MARIADB="mariadb-server"
            PKG_AVAHI="avahi"
            PKG_APACHE="httpd"
            PKG_PHP="php php-mysqlnd"
            PKG_PHPMYADMIN="phpMyAdmin"
            PKG_DEBCONF_UTILS=""
            PKG_CURL="curl"
            APACHE_SERVICE="httpd"
            ;;
        arch)
            PKG_MARIADB="mariadb"
            PKG_AVAHI="avahi"
            PKG_APACHE="apache"
            PKG_PHP="php php-apache php-mysqli"
            PKG_PHPMYADMIN="phpmyadmin"
            PKG_DEBCONF_UTILS=""
            PKG_CURL="curl"
            APACHE_SERVICE="httpd"
            ;;
        suse)
            PKG_MARIADB="mariadb"
            PKG_AVAHI="avahi"
            PKG_APACHE="apache2"
            PKG_PHP="php8 apache2-mod_php8 php8-mysql"
            PKG_PHPMYADMIN="phpMyAdmin"
            PKG_DEBCONF_UTILS=""
            PKG_CURL="curl"
            APACHE_SERVICE="apache2"
            ;;
    esac
}

# =============================================================================
# MariaDB Config-Pfad ermitteln
# =============================================================================
find_mariadb_config() {
    local paths=(
        "/etc/mysql/mariadb.conf.d/50-server.cnf"
        "/etc/my.cnf.d/mariadb-server.cnf"
        "/etc/my.cnf.d/server.cnf"
        "/etc/my.cnf"
    )
    for p in "${paths[@]}"; do
        if [ -f "$p" ]; then
            MARIADB_CONFIG="$p"
            return 0
        fi
    done
    MARIADB_CONFIG=""
    return 1
}

# =============================================================================
# Apache-Konfigurationspfade
# =============================================================================
get_apache_conf_dir() {
    case "$DISTRO_FAMILY" in
        debian)
            APACHE_CONF_DIR="/etc/apache2"
            APACHE_PORTS_CONF="/etc/apache2/ports.conf"
            APACHE_SITES_DIR="/etc/apache2/sites-available"
            ;;
        rhel)
            APACHE_CONF_DIR="/etc/httpd/conf"
            APACHE_PORTS_CONF="/etc/httpd/conf/httpd.conf"
            APACHE_SITES_DIR="/etc/httpd/conf.d"
            ;;
        arch)
            APACHE_CONF_DIR="/etc/httpd/conf"
            APACHE_PORTS_CONF="/etc/httpd/conf/httpd.conf"
            APACHE_SITES_DIR="/etc/httpd/conf/extra"
            ;;
        suse)
            APACHE_CONF_DIR="/etc/apache2"
            APACHE_PORTS_CONF="/etc/apache2/listen.conf"
            APACHE_SITES_DIR="/etc/apache2/conf.d"
            ;;
    esac
}

# =============================================================================
# phpMyAdmin DocumentRoot ermitteln
# =============================================================================
get_phpmyadmin_docroot() {
    local paths=(
        "/usr/share/phpmyadmin"
        "/usr/share/phpMyAdmin"
        "/srv/http/phpMyAdmin"
    )
    for p in "${paths[@]}"; do
        if [ -d "$p" ]; then
            PHPMYADMIN_DOCROOT="$p"
            return 0
        fi
    done
    # Fallback - wird nach Installation nochmal geprueft
    PHPMYADMIN_DOCROOT="/usr/share/phpmyadmin"
}

# =============================================================================
# Initialisierung
# =============================================================================
detect_distro
set_package_names
get_apache_conf_dir

# Voraussetzungen: curl wird fuer alles benoetigt (Docker-Install, Downloads, etc.)
if ! command -v curl &> /dev/null; then
    echo "[INFO] curl ist nicht installiert. Wird jetzt installiert..."
    pkg_update
    pkg_install $PKG_CURL
    echo "[OK] curl installiert."
fi

# python3 wird fuer Release-Download benoetigt
if ! command -v python3 &> /dev/null; then
    echo "[INFO] python3 ist nicht installiert. Wird jetzt installiert..."
    pkg_install python3
    echo "[OK] python3 installiert."
fi

INSTALL_DIR="$HOME/solarmanager"
GITHUB_RELEASE_REPO="BBessler/Solarmanager"
REPO_RAW="https://raw.githubusercontent.com/$GITHUB_RELEASE_REPO/main"

echo "============================================"
echo "  Solarmanager - Docker Installation"
echo "============================================"
echo ""

# =============================================================================
# Phase 1: Benutzereingaben (vor allem anderen, damit nichts uebersprungen wird)
# =============================================================================
echo ""
read -rp "Hostname fuer den Solarmanager [solarmanager.local]: " hostname
hostname=${hostname:-solarmanager.local}

read -rp "Datenbank-Passwort [solarmanager]: " db_password
db_password=${db_password:-solarmanager}

echo ""
echo "[INFO] Hostname:    $hostname"
echo "[INFO] DB-Passwort: $db_password"
echo ""

# =============================================================================
# Phase 2: Hostname / mDNS einrichten
# =============================================================================
if [[ "$hostname" == *.local ]]; then
    SHORT_HOST="${hostname%.local}"
    echo "[INFO] Setze Hostname auf '$SHORT_HOST'..."
    echo "$SHORT_HOST" | sudo tee /etc/hostname > /dev/null
    sudo hostnamectl set-hostname "$SHORT_HOST" 2>/dev/null || true
    if ! grep -q "$SHORT_HOST" /etc/hosts; then
        sudo bash -c "echo '127.0.1.1	$SHORT_HOST' >> /etc/hosts"
    fi

    if ! pkg_installed "$PKG_AVAHI"; then
        pkg_update
        pkg_install $PKG_AVAHI
    fi
    # Avahi-Service-Name variiert je nach Distro
    local_avahi_service="avahi-daemon"
    if [ "$DISTRO_FAMILY" != "debian" ]; then
        local_avahi_service="avahi-daemon"
    fi
    sudo systemctl enable "$local_avahi_service"
    sudo systemctl restart "$local_avahi_service"
    echo "[OK] Hostname '$SHORT_HOST' gesetzt, mDNS aktiv - '$hostname' im Netzwerk erreichbar."
fi

# =============================================================================
# Phase 3: MariaDB nativ installieren und einrichten
# =============================================================================
echo ""
echo "[INFO] MariaDB einrichten..."
if ! pkg_installed "$PKG_MARIADB"; then
    echo "[INFO] Installiere MariaDB..."
    pkg_update
    pkg_install $PKG_MARIADB

    # Arch: MariaDB muss nach Installation initialisiert werden
    if [ "$DISTRO_FAMILY" = "arch" ]; then
        sudo mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql
    fi

    echo "[OK] MariaDB installiert."
fi

# MariaDB sicherstellen dass sie laeuft
sudo systemctl enable mariadb
sudo systemctl start mariadb

# MariaDB fuer Zugriff aus Docker konfigurieren (auf 0.0.0.0 binden)
if find_mariadb_config; then
    if grep -q "^bind-address" "$MARIADB_CONFIG" 2>/dev/null; then
        sudo sed -i 's/^bind-address\s*=.*/bind-address = 0.0.0.0/' "$MARIADB_CONFIG"
        sudo systemctl restart mariadb
    fi
else
    echo "[WARNUNG] MariaDB-Konfigurationsdatei nicht gefunden. bind-address manuell auf 0.0.0.0 setzen."
fi

# DB-User und Datenbanken einrichten
SQL_FILE=$(mktemp)
cat > "$SQL_FILE" <<SQLEOF
CREATE USER IF NOT EXISTS 'pi'@'%' IDENTIFIED VIA mysql_native_password USING PASSWORD('$db_password');
ALTER USER 'pi'@'%' IDENTIFIED VIA mysql_native_password USING PASSWORD('$db_password');
GRANT ALL PRIVILEGES ON *.* TO 'pi'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
CREATE DATABASE IF NOT EXISTS solardb;
CREATE DATABASE IF NOT EXISTS ocpp;
SQLEOF

set +e
# Versuch 1: unix_socket (Standard bei MariaDB)
sudo mysql < "$SQL_FILE" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    # Versuch 2: mit Passwort (falls root bereits auf Passwort-Auth geaendert wurde)
    sudo mysql -u root -p"$db_password" < "$SQL_FILE" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "[WARNUNG] MariaDB-User konnte nicht eingerichtet werden."
        echo "          Bitte manuell pruefen: sudo mysql"
        rm -f "$SQL_FILE"
    fi
fi
set -e
rm -f "$SQL_FILE" 2>/dev/null || true

echo "[OK] MariaDB eingerichtet."

# =============================================================================
# Phase 3b: phpMyAdmin nativ installieren
# =============================================================================
echo ""
echo "[INFO] phpMyAdmin einrichten..."

install_phpmyadmin_debian() {
    pkg_update
    pkg_install $PKG_APACHE $PKG_PHP $PKG_DEBCONF_UTILS
    echo "phpmyadmin phpmyadmin/dbconfig-install boolean true" | sudo debconf-set-selections
    echo "phpmyadmin phpmyadmin/app-password-confirm password $db_password" | sudo debconf-set-selections
    echo "phpmyadmin phpmyadmin/mysql/admin-pass password $db_password" | sudo debconf-set-selections
    echo "phpmyadmin phpmyadmin/mysql/app-pass password $db_password" | sudo debconf-set-selections
    echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" | sudo debconf-set-selections
    pkg_install $PKG_PHPMYADMIN
}

install_phpmyadmin_rhel() {
    # EPEL aktivieren fuer phpMyAdmin
    if ! pkg_installed "epel-release"; then
        pkg_install epel-release
    fi
    pkg_install $PKG_APACHE $PKG_PHP $PKG_PHPMYADMIN
}

install_phpmyadmin_arch() {
    pkg_install $PKG_APACHE $PKG_PHP $PKG_PHPMYADMIN
}

install_phpmyadmin_suse() {
    pkg_install $PKG_APACHE $PKG_PHP $PKG_PHPMYADMIN
}

if ! pkg_installed "$PKG_PHPMYADMIN"; then
    case "$DISTRO_FAMILY" in
        debian) install_phpmyadmin_debian ;;
        rhel)   install_phpmyadmin_rhel ;;
        arch)   install_phpmyadmin_arch ;;
        suse)   install_phpmyadmin_suse ;;
    esac
    echo "[OK] phpMyAdmin installiert."
else
    echo "[INFO] phpMyAdmin ist bereits installiert."
fi

# phpMyAdmin DocumentRoot ermitteln
get_phpmyadmin_docroot

# Apache auf Port 8081 konfigurieren (Caddy uebernimmt 80/443)
configure_apache_debian() {
    if ! grep -q 'Listen 8081' "$APACHE_PORTS_CONF"; then
        sudo bash -c "echo 'Listen 8081' >> $APACHE_PORTS_CONF"
    fi
    # Standard-Ports entfernen damit kein Konflikt mit Caddy
    sudo sed -i 's/^Listen 80$/# Listen 80/' "$APACHE_PORTS_CONF"
    sudo sed -i 's/^Listen 443$/# Listen 443/' "$APACHE_PORTS_CONF"

    # VirtualHost fuer phpMyAdmin
    sudo tee "$APACHE_SITES_DIR/phpmyadmin.conf" > /dev/null <<EOF
<VirtualHost *:8081>
    DocumentRoot $PHPMYADMIN_DOCROOT
    <Directory $PHPMYADMIN_DOCROOT>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF
    sudo a2ensite phpmyadmin.conf > /dev/null 2>&1
    sudo a2dissite 000-default.conf > /dev/null 2>&1

    if ! grep -q "Include /etc/phpmyadmin/apache.conf" /etc/apache2/apache2.conf 2>/dev/null; then
        if [ -f /etc/phpmyadmin/apache.conf ]; then
            sudo bash -c "echo 'Include /etc/phpmyadmin/apache.conf' >> /etc/apache2/apache2.conf"
        fi
    fi
}

configure_apache_rhel() {
    # Listen 8081 hinzufuegen, Standard-Ports entfernen
    if ! grep -q 'Listen 8081' "$APACHE_PORTS_CONF"; then
        sudo bash -c "echo 'Listen 8081' >> $APACHE_PORTS_CONF"
    fi
    sudo sed -i 's/^Listen 80$/# Listen 80/' "$APACHE_PORTS_CONF"
    sudo sed -i 's/^Listen 443$/# Listen 443/' "$APACHE_PORTS_CONF"

    # VirtualHost fuer phpMyAdmin
    sudo tee "$APACHE_SITES_DIR/phpmyadmin-vhost.conf" > /dev/null <<EOF
<VirtualHost *:8081>
    DocumentRoot $PHPMYADMIN_DOCROOT
    <Directory $PHPMYADMIN_DOCROOT>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF
}

configure_apache_arch() {
    # Listen 8081 hinzufuegen, Standard-Ports entfernen
    if ! grep -q 'Listen 8081' "$APACHE_PORTS_CONF"; then
        sudo bash -c "echo 'Listen 8081' >> $APACHE_PORTS_CONF"
    fi
    sudo sed -i 's/^Listen 80$/# Listen 80/' "$APACHE_PORTS_CONF"
    sudo sed -i 's/^Listen 443$/# Listen 443/' "$APACHE_PORTS_CONF"

    # VirtualHost fuer phpMyAdmin
    sudo tee "$APACHE_SITES_DIR/phpmyadmin.conf" > /dev/null <<EOF
<VirtualHost *:8081>
    DocumentRoot $PHPMYADMIN_DOCROOT
    <Directory $PHPMYADMIN_DOCROOT>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF
    # Include in httpd.conf falls noetig
    if ! grep -q 'Include conf/extra/phpmyadmin.conf' "$APACHE_PORTS_CONF"; then
        sudo bash -c "echo 'Include conf/extra/phpmyadmin.conf' >> $APACHE_PORTS_CONF"
    fi
}

configure_apache_suse() {
    # Listen 8081 hinzufuegen
    if ! grep -q 'Listen 8081' "$APACHE_PORTS_CONF"; then
        sudo bash -c "echo 'Listen 8081' >> $APACHE_PORTS_CONF"
    fi
    # Standard-Ports entfernen
    sudo sed -i 's/^Listen 80$/# Listen 80/' "$APACHE_PORTS_CONF"
    sudo sed -i 's/^Listen 443$/# Listen 443/' "$APACHE_PORTS_CONF"

    # VirtualHost fuer phpMyAdmin
    sudo tee "$APACHE_SITES_DIR/phpmyadmin.conf" > /dev/null <<EOF
<VirtualHost *:8081>
    DocumentRoot $PHPMYADMIN_DOCROOT
    <Directory $PHPMYADMIN_DOCROOT>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF
}

case "$DISTRO_FAMILY" in
    debian) configure_apache_debian ;;
    rhel)   configure_apache_rhel ;;
    arch)   configure_apache_arch ;;
    suse)   configure_apache_suse ;;
esac

sudo systemctl enable "$APACHE_SERVICE"
sudo systemctl restart "$APACHE_SERVICE"
echo "[OK] phpMyAdmin auf Port 8081 eingerichtet."

# Pruefen ob MariaDB erreichbar ist
set +e
sudo mysql -u pi -p"$db_password" -e "SELECT 1" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "[WARNUNG] MariaDB-Verbindung mit User 'pi' fehlgeschlagen."
    echo "          Bitte Passwort pruefen."
fi
set -e

# =============================================================================
# Phase 4: Docker pruefen / installieren
# =============================================================================
DOCKER_JUST_INSTALLED=false
if ! command -v docker &> /dev/null; then
    echo "[INFO] Docker ist nicht installiert. Wird jetzt installiert..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    DOCKER_JUST_INSTALLED=true
    echo "[OK] Docker wurde installiert."
fi

if [ "$DOCKER_JUST_INSTALLED" = true ]; then
    echo ""
    echo "[OK] MariaDB, phpMyAdmin und Docker wurden eingerichtet."
    echo ""
    echo "WICHTIG: Bitte einmal ab- und wieder anmelden, damit Docker ohne sudo funktioniert."
    echo "Danach dieses Script erneut ausfuehren um die Container zu starten."
    exit 0
fi

if ! docker compose version &> /dev/null; then
    echo "FEHLER: 'docker compose' ist nicht verfuegbar."
    exit 1
fi

echo "[OK] Docker ist installiert."

# =============================================================================
# Phase 5: Docker-Dateien und Releases herunterladen
# =============================================================================
echo ""
echo "[INFO] Erstelle Verzeichnis: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "[INFO] Lade Docker-Konfiguration herunter..."
curl -fsSL "$REPO_RAW/docker/docker-compose.yml" -o docker-compose.yml
curl -fsSL "$REPO_RAW/docker/Dockerfile" -o Dockerfile
curl -fsSL "$REPO_RAW/docker/Caddyfile" -o Caddyfile
curl -fsSL "$REPO_RAW/docker/.env.example" -o .env.example

# IP-Adresse automatisch ermitteln
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "[INFO] Erkannte IP-Adresse: $SERVER_IP"

# .env erstellen/aktualisieren
cp .env.example .env
sed -i "s|^SERVER_HOST=.*|SERVER_HOST=$hostname|" .env
sed -i "s|^SERVER_IP=.*|SERVER_IP=$SERVER_IP|" .env
sed -i "s|^MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=$db_password|" .env
sed -i "s|^MYSQL_PASSWORD=.*|MYSQL_PASSWORD=$db_password|" .env

echo "[OK] Konfiguration in $INSTALL_DIR/.env gespeichert."

echo ""
echo "[INFO] Lade Solarmanager Releases von GitHub herunter..."

RELEASES=$(curl -sL \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$GITHUB_RELEASE_REPO/releases")

if [ -z "$RELEASES" ] || echo "$RELEASES" | grep -q '"message"'; then
    echo "[FEHLER] GitHub API nicht erreichbar."
    exit 1
fi

download_release() {
    local tag_prefix="$1"
    local target_dir="$2"
    local name="$3"

    echo "[INFO] Suche neuestes $name Release (Tag: ${tag_prefix}*)..."

    local asset_info
    asset_info=$(echo "$RELEASES" | python3 -c "
import sys, json
releases = json.load(sys.stdin)
for r in releases:
    if r['tag_name'].startswith('$tag_prefix'):
        tag = r['tag_name']
        url = r['assets'][0]['browser_download_url'] if r['assets'] else ''
        print(tag + '|' + url)
        break
" 2>/dev/null)

    local tag=$(echo "$asset_info" | cut -d'|' -f1)
    local url=$(echo "$asset_info" | cut -d'|' -f2)

    if [ -z "$url" ]; then
        echo "[FEHLER] Kein Release gefunden fuer $name"
        return 1
    fi

    echo "[INFO] Lade $name $tag herunter..."
    local tmp_file="/tmp/sm-${name}-$$.tar.gz"
    curl -sL "$url" -o "$tmp_file"
    mkdir -p "$target_dir"
    tar -xzf "$tmp_file" -C "$target_dir"
    rm -f "$tmp_file"
    echo "[OK] $name $tag installiert."
}

# Backend nach ./app/
download_release "backend-" "$INSTALL_DIR/app" "Backend"

# Frontend nach ./app/wwwroot/
download_release "frontend-" "$INSTALL_DIR/app/wwwroot" "Frontend"

# Frontend-Konfiguration
echo "[INFO] Konfiguriere Frontend..."
cat > "$INSTALL_DIR/app/wwwroot/config.json" <<EOF
{
  "API_URL": "https://${hostname}/",
  "APP_ENV": "production"
}
EOF
echo "[OK] Frontend config.json konfiguriert."

# =============================================================================
# Phase 6: Docker Image bauen und Container starten
# =============================================================================
echo ""
# Falls beim letzten Lauf der IPv4-Fallback gesetzt wurde, erneut aktivieren
if [ -f /etc/docker/daemon.json ] && grep -q "ip6tables" /etc/docker/daemon.json 2>/dev/null; then
    echo "[INFO] IPv4-Fallback aus vorherigem Lauf erkannt, deaktiviere IPv6..."
    sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1 > /dev/null 2>&1
    sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1 > /dev/null 2>&1
fi

echo "[INFO] Baue Docker Image und starte Container..."
MAX_RETRIES=3
RETRY=0
until docker compose build && docker compose up -d; do
    RETRY=$((RETRY + 1))
    if [ $RETRY -ge $MAX_RETRIES ]; then
        echo "[WARNUNG] Docker-Start nach $MAX_RETRIES Versuchen fehlgeschlagen."
        echo "[INFO] Versuche mit IPv4-Fallback..."
        # Docker auf IPv4 zwingen via sysctl und daemon.json
        sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1 > /dev/null 2>&1
        sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1 > /dev/null 2>&1
        sudo tee /etc/docker/daemon.json > /dev/null <<DEOF
{
  "ip6tables": false,
  "dns": ["8.8.8.8", "8.8.4.4"]
}
DEOF
        sudo systemctl restart docker
        sleep 5
        if docker compose build && docker compose up -d; then
            echo "[OK] Docker-Start mit IPv4-Fallback erfolgreich."
        else
            echo "[FEHLER] Docker-Start auch mit IPv4-Fallback fehlgeschlagen."
            exit 1
        fi
        break
    fi
    echo "[WARNUNG] Docker-Fehler. Neuer Versuch ($RETRY/$MAX_RETRIES) in 10 Sekunden..."
    sleep 10
done

echo ""
echo "[INFO] Warte auf Backend-Start..."
WAIT=0
MAX_WAIT=60
while [ $WAIT -lt $MAX_WAIT ]; do
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:8080 2>/dev/null | grep -q "200\|301\|302\|404"; then
        break
    fi
    sleep 2
    WAIT=$((WAIT + 2))
    printf "\r[INFO] Warte auf Backend... %ds / %ds" "$WAIT" "$MAX_WAIT"
done
echo ""
if [ $WAIT -ge $MAX_WAIT ]; then
    echo "[WARNUNG] Backend antwortet noch nicht. Bitte manuell pruefen: docker compose logs -f"
else
    echo "[OK] Backend ist bereit."
fi

echo ""
echo "============================================"
echo "  Installation abgeschlossen!"
echo "============================================"
echo ""
echo "Zugriff:"
echo "  Frontend:       https://$hostname"
echo "  API/Swagger:    https://$hostname/swagger"
echo "  phpMyAdmin:     https://$hostname/phpmyadmin"
echo "  Portainer:      https://$hostname:9443"
echo ""
echo "Nuetzliche Befehle:"
echo "  cd $INSTALL_DIR"
echo "  docker compose logs -f          # Logs anzeigen"
echo "  docker compose restart           # Neu starten"
echo "  docker compose down              # Stoppen"
echo "  docker compose up -d             # Starten"
echo ""
echo "HINWEIS: Self-Signed-Zertifikat - Browser-Warnung beim ersten Zugriff bestaetigen."
