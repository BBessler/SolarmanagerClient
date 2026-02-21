#!/bin/bash

# Stoppe bei Fehlern
set -e

GITHUB_RELEASE_REPO="BBessler/SolarmanagerClient"
WEB_DIR="/var/www/html"

echo "### Solarmanager Update ###"
echo ""

# Funktion: Neuestes Release-Asset nach Tag-Prefix herunterladen und entpacken
download_latest_release() {
  local tag_prefix="$1"
  local target_dir="$2"
  local name="$3"

  echo "[INFO] Lade neuestes $name Release..."

  local release_info
  release_info=$(curl -sL \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$GITHUB_RELEASE_REPO/releases")

  local asset_url
  asset_url=$(echo "$release_info" | python3 -c "
import sys, json
releases = json.load(sys.stdin)
for r in releases:
    if r['tag_name'].startswith('$tag_prefix'):
        if r['assets']:
            print(r['assets'][0]['browser_download_url'])
        break
" 2>/dev/null)

  if [ -z "$asset_url" ]; then
    echo "[FEHLER] Kein Release-Asset gefunden für $name (Tag-Prefix: $tag_prefix)"
    return 1
  fi

  # Version anzeigen
  local tag_name
  tag_name=$(echo "$release_info" | python3 -c "
import sys, json
releases = json.load(sys.stdin)
for r in releases:
    if r['tag_name'].startswith('$tag_prefix'):
        print(r['tag_name'])
        break
" 2>/dev/null)
  echo "[INFO] Version: $tag_name"

  local tmp_file="/tmp/${name}-latest.tar.gz"

  curl -sL "$asset_url" -o "$tmp_file"

  sudo mkdir -p "$target_dir"
  sudo tar -xzf "$tmp_file" -C "$target_dir"
  rm -f "$tmp_file"

  echo "[OK] $name nach $target_dir entpackt."
}

# Backend aktualisieren
echo "--- Backend ---"
download_latest_release "backend-" "$WEB_DIR/backend" "Backend"
echo ""

# Frontend aktualisieren (config.json sichern und wiederherstellen)
echo "--- Frontend ---"
CONFIG_BACKUP=""
if [ -f "$WEB_DIR/config.json" ]; then
  CONFIG_BACKUP=$(cat "$WEB_DIR/config.json")
  echo "[INFO] config.json gesichert."
fi

download_latest_release "frontend-" "$WEB_DIR" "Frontend"

if [ -n "$CONFIG_BACKUP" ]; then
  echo "$CONFIG_BACKUP" | sudo tee "$WEB_DIR/config.json" > /dev/null
  echo "[OK] config.json wiederhergestellt."
fi

# Rechte setzen
echo ""
echo "[INFO] Setze Dateirechte..."
sudo chown -R pi:pi "$WEB_DIR"
sudo find "$WEB_DIR" -type d -exec chmod 755 {} \;
sudo find "$WEB_DIR" -type f -exec chmod 644 {} \;

# Backend neu starten
echo "[INFO] Starte Backend neu..."
sudo systemctl restart solarmanager.service

echo ""
echo "### Update abgeschlossen! ###"
