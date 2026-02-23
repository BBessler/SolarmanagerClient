#!/bin/bash
# =============================================================================
# Solarmanager - Docker Installation
# Laedt Releases herunter und startet alles via Docker Compose
# =============================================================================

set -e

INSTALL_DIR="$HOME/solarmanager"
GITHUB_RELEASE_REPO="BBessler/SolarmanagerClient"
REPO_RAW="https://raw.githubusercontent.com/$GITHUB_RELEASE_REPO/main"

echo "============================================"
echo "  Solarmanager - Docker Installation"
echo "============================================"
echo ""

# ----- Docker pruefen / installieren -----
if ! command -v docker &> /dev/null; then
    echo "Docker ist nicht installiert. Wird jetzt installiert..."
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
    echo "Bitte stellen Sie sicher, dass Docker Compose installiert ist."
    exit 1
fi

# ----- Installationsverzeichnis -----
echo "Erstelle Verzeichnis: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ----- Docker-Dateien herunterladen -----
echo "Lade Docker-Konfiguration herunter..."
curl -fsSL "$REPO_RAW/docker/docker-compose.yml" -o docker-compose.yml
curl -fsSL "$REPO_RAW/docker/Dockerfile" -o Dockerfile
curl -fsSL "$REPO_RAW/docker/Caddyfile" -o Caddyfile
curl -fsSL "$REPO_RAW/docker/.env.example" -o .env.example

# ----- .env erstellen (nur wenn noch nicht vorhanden) -----
if [ ! -f .env ]; then
    cp .env.example .env

    echo ""
    echo "--- Konfiguration ---"
    echo ""

    # Hostname
    read -rp "Hostname fuer den Solarmanager [solarmanager.local]: " hostname
    hostname=${hostname:-solarmanager.local}
    sed -i "s|^SERVER_HOST=.*|SERVER_HOST=$hostname|" .env

    # Hostname einrichten (mDNS)
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

    # Datenbank-Passwort
    read -rp "Datenbank-Passwort [solarmanager]: " db_password
    db_password=${db_password:-solarmanager}
    sed -i "s|^MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=$db_password|" .env
    sed -i "s|^MYSQL_PASSWORD=.*|MYSQL_PASSWORD=$db_password|" .env

    echo ""
    echo "[OK] Konfiguration in $INSTALL_DIR/.env gespeichert."
else
    echo ".env existiert bereits - wird nicht ueberschrieben."
    # Hostname aus .env lesen
    hostname=$(grep "^SERVER_HOST=" .env | cut -d'=' -f2)
fi

# ----- Releases herunterladen -----
echo ""
echo "Lade Solarmanager Releases von GitHub herunter..."

RELEASES=$(curl -sL \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$GITHUB_RELEASE_REPO/releases")

if [ -z "$RELEASES" ] || echo "$RELEASES" | grep -q '"message"'; then
    echo "[FEHLER] GitHub API nicht erreichbar."
    exit 1
fi

# Neuestes Release-Asset nach Tag-Prefix finden und herunterladen
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

# ----- Frontend-Konfiguration -----
echo "[INFO] Konfiguriere Frontend..."
cat > "$INSTALL_DIR/app/wwwroot/config.json" <<EOF
{
  "API_URL": "https://${hostname}/",
  "APP_ENV": "production"
}
EOF
echo "[OK] Frontend config.json konfiguriert."

# ----- Docker Image bauen und Container starten -----
echo ""
echo "Baue Docker Image und starte Container..."
docker compose build
docker compose up -d

echo ""
echo "============================================"
echo "  Installation abgeschlossen!"
echo "============================================"
echo ""
echo "Zugriff:"
echo "  Frontend:    https://$hostname"
echo "  API/Swagger: https://$hostname/swagger"
echo ""
echo "Nuetzliche Befehle:"
echo "  cd $INSTALL_DIR"
echo "  docker compose logs -f          # Logs anzeigen"
echo "  docker compose restart           # Neu starten"
echo "  docker compose down              # Stoppen"
echo "  docker compose up -d             # Starten"
echo ""
echo "HINWEIS: Self-Signed-Zertifikat - Browser-Warnung beim ersten Zugriff bestaetigen."
