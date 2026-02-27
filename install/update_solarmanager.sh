#!/bin/bash

# Solarmanager Update
# Laedt die neuesten Releases herunter und aktualisiert Backend/Frontend

set -e

# Update-Channel: stable (Standard) oder beta
CHANNEL="stable"
if [[ "$1" == "--beta" ]]; then
    CHANNEL="beta"
fi

GITHUB_RELEASE_REPO="BBessler/Solarmanager"
WEB_DIR="/var/www/html"
VERSION_FILE="/var/www/html/.solarmanager_versions"

echo "### Solarmanager Update ($CHANNEL) ###"
echo ""

# Installierte Versionen laden (falls vorhanden)
INSTALLED_BACKEND="(unbekannt)"
INSTALLED_FRONTEND="(unbekannt)"
if [ -f "$VERSION_FILE" ]; then
  . "$VERSION_FILE"
fi

# Alle Releases einmalig abfragen
echo "[INFO] Pruefe auf neue Versionen..."
RELEASES=$(curl -sL \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$GITHUB_RELEASE_REPO/releases")

if [ -z "$RELEASES" ] || echo "$RELEASES" | grep -q '"message"'; then
  echo "[FEHLER] GitHub API nicht erreichbar."
  exit 1
fi

# Neueste Version und Download-URL fuer ein Tag-Prefix ermitteln
get_latest() {
  local tag_prefix="$1"
  local channel="$2"
  echo "$RELEASES" | python3 -c "
import sys, json
releases = json.load(sys.stdin)
channel = '$channel'
for r in releases:
    is_pre = r.get('prerelease', False)
    if channel == 'beta' and not is_pre:
        continue
    if channel == 'stable' and is_pre:
        continue
    if r['tag_name'].startswith('$tag_prefix'):
        url = r['assets'][0]['browser_download_url'] if r['assets'] else ''
        print(r['tag_name'] + '|' + url)
        break
" 2>/dev/null
}

# Release herunterladen und entpacken
download_and_extract() {
  local asset_url="$1"
  local target_dir="$2"
  local tmp_file="/tmp/sm-update-$$.tar.gz"

  curl -sL "$asset_url" -o "$tmp_file"
  sudo mkdir -p "$target_dir"
  sudo tar -xzf "$tmp_file" -C "$target_dir"
  rm -f "$tmp_file"
}

if [ "$CHANNEL" = "beta" ]; then
  LATEST_BACKEND_INFO=$(get_latest "beta-backend-" "beta")
  LATEST_FRONTEND_INFO=$(get_latest "beta-frontend-" "beta")
else
  LATEST_BACKEND_INFO=$(get_latest "backend-" "stable")
  LATEST_FRONTEND_INFO=$(get_latest "frontend-" "stable")
fi

LATEST_BACKEND_TAG=$(echo "$LATEST_BACKEND_INFO" | cut -d'|' -f1)
LATEST_BACKEND_URL=$(echo "$LATEST_BACKEND_INFO" | cut -d'|' -f2)

LATEST_FRONTEND_TAG=$(echo "$LATEST_FRONTEND_INFO" | cut -d'|' -f1)
LATEST_FRONTEND_URL=$(echo "$LATEST_FRONTEND_INFO" | cut -d'|' -f2)

echo ""
echo "  Installiert        Verfuegbar"
echo "  Backend:  $INSTALLED_BACKEND  ->  $LATEST_BACKEND_TAG"
echo "  Frontend: $INSTALLED_FRONTEND  ->  $LATEST_FRONTEND_TAG"
echo ""

if [ "$LATEST_BACKEND_TAG" = "$INSTALLED_BACKEND" ] && [ "$LATEST_FRONTEND_TAG" = "$INSTALLED_FRONTEND" ]; then
  echo "[INFO] Alles aktuell."
  read -p "Trotzdem neu installieren? (j/n) [n]: " CONFIRM
  CONFIRM="${CONFIRM:-n}"
  if [[ ! "$CONFIRM" =~ ^[Jj]$ ]]; then
    echo "[INFO] Abgebrochen."
    exit 0
  fi
else
  read -p "Update jetzt durchfuehren? (j/n) [j]: " CONFIRM
CONFIRM="${CONFIRM:-j}"
  if [[ ! "$CONFIRM" =~ ^[Jj]$ ]]; then
    echo "[INFO] Update abgebrochen."
    exit 0
  fi
fi

# Backend aktualisieren
if [ -n "$LATEST_BACKEND_TAG" ]; then
  echo ""
  echo "[INFO] Backend aktualisieren: $LATEST_BACKEND_TAG..."
  download_and_extract "$LATEST_BACKEND_URL" "$WEB_DIR/backend"
  echo "[OK] Backend aktualisiert."
fi

# Frontend aktualisieren
if [ -n "$LATEST_FRONTEND_TAG" ]; then
  echo "[INFO] Frontend aktualisieren: $LATEST_FRONTEND_TAG..."

  # config.json sichern
  CONFIG_BACKUP=""
  if [ -f "$WEB_DIR/config.json" ]; then
    CONFIG_BACKUP=$(cat "$WEB_DIR/config.json")
  fi

  download_and_extract "$LATEST_FRONTEND_URL" "$WEB_DIR"

  # config.json wiederherstellen
  if [ -n "$CONFIG_BACKUP" ]; then
    echo "$CONFIG_BACKUP" | sudo tee "$WEB_DIR/config.json" > /dev/null
    echo "[OK] config.json wiederhergestellt."
  fi
  echo "[OK] Frontend aktualisiert."
fi

# Rechte setzen
sudo chown -R pi:pi "$WEB_DIR"
sudo find "$WEB_DIR" -type d -exec chmod 755 {} \;
sudo find "$WEB_DIR" -type f -exec chmod 644 {} \;

# Backend neu starten
echo "[INFO] Starte Backend neu..."
sudo systemctl restart solarmanager.service

echo "[INFO] Warte auf Backend-Start..."
WAIT=0
MAX_WAIT=60
while [ $WAIT -lt $MAX_WAIT ]; do
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:5000 2>/dev/null | grep -q "200\|301\|302\|404"; then
        break
    fi
    sleep 2
    WAIT=$((WAIT + 2))
    printf "\r[INFO] Warte auf Backend... %ds / %ds" "$WAIT" "$MAX_WAIT"
done
echo ""
if [ $WAIT -ge $MAX_WAIT ]; then
    echo "[WARNUNG] Backend antwortet noch nicht. Bitte manuell pruefen: sudo systemctl status solarmanager.service"
else
    echo "[OK] Backend ist bereit."
fi

# Installierte Versionen speichern
sudo tee "$VERSION_FILE" > /dev/null <<EOF
INSTALLED_BACKEND="$LATEST_BACKEND_TAG"
INSTALLED_FRONTEND="$LATEST_FRONTEND_TAG"
EOF

echo ""
echo "### Update abgeschlossen! ###"
