#!/bin/bash
# =============================================================================
# Solarmanager - Docker Installation
# MariaDB nativ, Backend + Caddy + Portainer in Docker
# Kann beliebig oft aufgerufen werden (idempotent)
# =============================================================================

set -e

INSTALL_DIR="$HOME/solarmanager"
GITHUB_RELEASE_REPO="BBessler/Solarmanager"
REPO_RAW="https://raw.githubusercontent.com/$GITHUB_RELEASE_REPO/main"

echo "============================================"
echo "  Solarmanager - Docker Installation"
echo "============================================"
echo ""

# =============================================================================
# Phase 1: Docker pruefen / installieren (muss zuerst passieren)
# =============================================================================
if ! command -v docker &> /dev/null; then
    echo "[INFO] Docker ist nicht installiert. Wird jetzt installiert..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    echo ""
    echo "[OK] Docker wurde installiert."
    echo "WICHTIG: Bitte einmal ab- und wieder anmelden, damit Docker ohne sudo funktioniert."
    echo "Danach dieses Script erneut ausfuehren."
    exit 0
fi

if ! docker compose version &> /dev/null; then
    echo "FEHLER: 'docker compose' ist nicht verfuegbar."
    exit 1
fi

echo "[OK] Docker ist installiert."

# =============================================================================
# Phase 2: Benutzereingaben
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
# Phase 3: Hostname / mDNS einrichten
# =============================================================================
if [[ "$hostname" == *.local ]]; then
    SHORT_HOST="${hostname%.local}"
    echo "[INFO] Setze Hostname auf '$SHORT_HOST'..."
    echo "$SHORT_HOST" | sudo tee /etc/hostname > /dev/null
    sudo hostnamectl set-hostname "$SHORT_HOST" 2>/dev/null || true
    if ! grep -q "$SHORT_HOST" /etc/hosts; then
        sudo bash -c "echo '127.0.1.1	$SHORT_HOST' >> /etc/hosts"
    fi
    if ! dpkg -s avahi-daemon &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y avahi-daemon
    fi
    sudo systemctl enable avahi-daemon
    sudo systemctl start avahi-daemon
    echo "[OK] mDNS aktiv - '$hostname' im Netzwerk erreichbar."
fi

# =============================================================================
# Phase 4: MariaDB nativ installieren und einrichten
# =============================================================================
echo ""
echo "[INFO] MariaDB einrichten..."
if ! dpkg -s mariadb-server &> /dev/null; then
    echo "[INFO] Installiere MariaDB..."
    sudo apt-get update
    sudo apt-get install -y mariadb-server
    echo "[OK] MariaDB installiert."
fi

# MariaDB sicherstellen dass sie laeuft
sudo systemctl enable mariadb
sudo systemctl start mariadb

# MariaDB fuer Zugriff aus Docker konfigurieren (auf 0.0.0.0 binden)
if grep -q "^bind-address" /etc/mysql/mariadb.conf.d/50-server.cnf 2>/dev/null; then
    sudo sed -i 's/^bind-address\s*=.*/bind-address = 0.0.0.0/' /etc/mysql/mariadb.conf.d/50-server.cnf
    sudo systemctl restart mariadb
fi

# DB-User und Datenbanken einrichten
SQL_FILE=$(mktemp)
cat > "$SQL_FILE" <<SQLEOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$db_password';
CREATE USER IF NOT EXISTS 'pi'@'%' IDENTIFIED BY '$db_password';
GRANT ALL PRIVILEGES ON *.* TO 'pi'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
CREATE DATABASE IF NOT EXISTS solardb;
CREATE DATABASE IF NOT EXISTS ocpp;
SQLEOF

set +e
sudo mysql < "$SQL_FILE" > /dev/null 2>&1
if [ $? -ne 0 ]; then
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

# Pruefen ob MariaDB erreichbar ist
set +e
sudo mysql -u pi -p"$db_password" -e "SELECT 1" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "[WARNUNG] MariaDB-Verbindung mit User 'pi' fehlgeschlagen."
    echo "          Bitte Passwort pruefen."
fi
set -e

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
echo "[INFO] Baue Docker Image und starte Container..."
docker compose build
docker compose up -d

echo ""
echo "============================================"
echo "  Installation abgeschlossen!"
echo "============================================"
echo ""
echo "Zugriff:"
echo "  Frontend:       https://$hostname"
echo "  API/Swagger:    https://$hostname/swagger"
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
