# Solarmanager

Energiemanagementsystem zur intelligenten Steuerung von PV-Anlagen, Wallboxen, Batteriespeichern und Fahrzeugladung.

![Dashboard](images/Dashboard.jpg)

### Features

| | |
|---|---|
| ![Dashboard](images/Dashboard_einfach.jpg) | **Dashboard** — Live-Ansicht mit PV-Produktion, Verbrauch, Akku-Status, Wallbox und Wettervorhersage |
| ![Auswertungen](images/Auswertungen.jpg) | **Auswertungen** — Monats- und Jahresvergleiche von PV-Leistung, Bezug, Einspeisung und Verbrauch |
| ![Simulation](images/Simulation.jpg) | **Simulation** — Ladesimulation mit Prognose: Wie lange dauert die Ladung bei aktuellem Wetter? |
| ![Einstellungen](images/Einstellungen.jpg) | **Einstellungen** — Konfiguration von PV-Anlagen, Akkus, Wallboxen, Autos, Verbrauchern und Prognosen |

---

## Voraussetzungen

- Raspberry Pi (empfohlen: Pi 4 oder neuer) mit Raspberry Pi OS (Debian-basiert)
- Internetverbindung
- SSH-Zugang zum Pi

---

## Installation mit Docker (empfohlen)

Docker vereinfacht die Installation und Updates auf einen einzigen Befehl.

### Setup

```bash
wget https://raw.githubusercontent.com/BBessler/Solarmanager/main/install/setup_docker.sh
chmod +x setup_docker.sh
./setup_docker.sh
```

> [!NOTE]
> Falls Docker noch nicht installiert ist, wird es automatisch eingerichtet. Danach muss man sich einmal **neu einloggen** (SSH-Session schließen und öffnen) und das Script erneut ausführen.

Das Script installiert automatisch:
- Docker (falls nicht vorhanden)
- Solarmanager Backend + Frontend (neueste GitHub-Releases)
- MariaDB Datenbank (nativ auf dem Host)
- phpMyAdmin (Datenbank-Verwaltung)
- Caddy Reverse-Proxy mit HTTPS (Self-Signed-Zertifikat)
- Portainer (Docker-Verwaltung im Browser)
- mDNS/Avahi (bei `.local`-Hostname)
- Frontend-Konfiguration (API-URL automatisch gesetzt)

### Update

```bash
wget -O update_docker.sh https://raw.githubusercontent.com/BBessler/Solarmanager/main/install/update_docker.sh
chmod +x update_docker.sh
./update_docker.sh
```

### Zugriff

| Dienst | URL |
|--------|-----|
| Frontend | `https://solarmanager.local` |
| API/Swagger | `https://solarmanager.local/swagger` |
| phpMyAdmin | `https://solarmanager.local/phpmyadmin` |
| Portainer (Docker-Verwaltung) | `https://solarmanager.local:9443` |

> [!TIP]
> **phpMyAdmin:** Login mit den DB-Zugangsdaten (Standard: `pi` / `solarmanager`).

> [!NOTE]
> Da ein Self-Signed-Zertifikat verwendet wird, zeigt der Browser beim ersten Zugriff eine Sicherheitswarnung an. Diese muss einmalig bestätigt werden:
> - **Chrome/Edge:** „Erweitert" → „Weiter zu … (unsicher)"
> - **Firefox:** „Erweitert…" → „Risiko akzeptieren und fortfahren"
> - **Safari:** „Details einblenden" → „Diese Website besuchen"

> [!NOTE]
> Nach dem Start kann es **2–5 Minuten** dauern, bis alle Dienste erreichbar sind, da die Datenbank beim ersten Start eingerichtet wird. Mit folgendem Befehl kann der Status geprüft werden:
> ```bash
> cd ~/solarmanager && docker compose ps
> ```

### Nützliche Befehle

```bash
cd ~/solarmanager
docker compose ps               # Status der Container prüfen
docker compose logs -f solarmanager  # Solarmanager-Logs anzeigen
docker compose logs -f          # Alle Logs anzeigen
docker compose restart           # Neu starten
docker compose down              # Stoppen
docker compose up -d             # Starten
```

### Manuelle Docker-Installation

<details>
<summary>Falls Docker bereits installiert ist oder die MariaDB auf einem anderen Server liegt</summary>

**1. Docker-Dateien herunterladen:**

```bash
mkdir -p ~/solarmanager && cd ~/solarmanager
wget https://raw.githubusercontent.com/BBessler/Solarmanager/main/docker/docker-compose.yml
wget https://raw.githubusercontent.com/BBessler/Solarmanager/main/docker/Dockerfile
wget https://raw.githubusercontent.com/BBessler/Solarmanager/main/docker/Caddyfile
wget https://raw.githubusercontent.com/BBessler/Solarmanager/main/docker/.env.example
cp .env.example .env
```

**2. `.env` anpassen:**

```env
SERVER_HOST=solarmanager.local
SERVER_IP=192.168.178.50

# DB-Zugangsdaten (ggf. IP des externen DB-Servers)
MYSQL_USER=pi
MYSQL_PASSWORD=solarmanager
```

**3. Bei externer Datenbank:** In `docker-compose.yml` den Connection String anpassen — `host.docker.internal` durch die IP des DB-Servers ersetzen:

```yaml
environment:
  - ConnectionDb=server=192.168.178.100;database=solardb;user=pi;password=solarmanager;Max Pool Size=500;
  - ConnectionStrings__MySQLServer_OCPP=server=192.168.178.100;database=ocpp;user=pi;password=solarmanager;Max Pool Size=500;
```

> [!WARNING]
> Der MariaDB-User muss Zugriff von der Docker-IP erlauben (`'pi'@'%'`), und `bind-address` in der MariaDB-Konfiguration muss auf `0.0.0.0` stehen.

**4. Releases herunterladen:**

Die neuesten Releases von der [Releases-Seite](https://github.com/BBessler/Solarmanager/releases) herunterladen und entpacken:

```bash
# Backend
mkdir -p ~/solarmanager/app
tar -xzf backend-*.tar.gz -C ~/solarmanager/app/

# Frontend
mkdir -p ~/solarmanager/app/wwwroot
tar -xzf frontend-*.tar.gz -C ~/solarmanager/app/wwwroot/
```

**5. Frontend konfigurieren:**

```bash
cat > ~/solarmanager/app/wwwroot/config.json <<EOF
{
  "API_URL": "https://solarmanager.local/",
  "APP_ENV": "production"
}
EOF
```

**6. Starten:**

```bash
cd ~/solarmanager
docker compose build
docker compose up -d
```

</details>

---

## Native Installation (ohne Docker)

> Alternative zur Docker-Installation. Installiert alle Komponenten direkt auf dem System.

### Setup

Per SSH auf dem Raspberry Pi einloggen und folgende Befehle ausführen:

```bash
wget https://raw.githubusercontent.com/BBessler/Solarmanager/main/install/setup_solarmanager.sh
chmod +x setup_solarmanager.sh
sudo ./setup_solarmanager.sh
```

Das Script installiert und konfiguriert automatisch:
- Apache Webserver mit PHP und SSL (Self-Signed-Zertifikat)
- MariaDB Datenbank
- phpMyAdmin
- .NET Runtime
- Python-Abhängigkeiten (Hyundai/BMW API)
- Firewall (UFW)
- Solarmanager Backend & Frontend (neuestes Release)
- Systemd-Service für den automatischen Start
- HTTP → HTTPS Redirects

### Datenbank einrichten (optional)

Falls eine bestehende Datenbank-Sicherung (`solardb.sql`) importiert werden soll:

```bash
wget https://raw.githubusercontent.com/BBessler/Solarmanager/main/install/setup_DB.sh
chmod +x setup_DB.sh
sudo ./setup_DB.sh
```

### Update

Um Backend und Frontend auf die neueste Version zu aktualisieren:

```bash
wget -O update_solarmanager.sh https://raw.githubusercontent.com/BBessler/Solarmanager/main/install/update_solarmanager.sh
chmod +x update_solarmanager.sh
sudo ./update_solarmanager.sh
```

Das Update-Script:
- Lädt die neuesten Releases herunter
- Sichert und stellt die Frontend-Konfiguration (`config.json`) automatisch wieder her
- Startet das Backend neu

### Zugriff

| Dienst | URL |
|--------|-----|
| Frontend | `https://solarmanager.local` |
| Backend-API | `https://solarmanager.local:453` |
| phpMyAdmin | `https://solarmanager.local/phpmyadmin` |

> [!NOTE]
> Da ein Self-Signed-Zertifikat verwendet wird, zeigt der Browser beim ersten Zugriff eine Sicherheitswarnung an. Diese muss einmalig bestätigt werden:
> - **Chrome/Edge:** „Erweitert" → „Weiter zu … (unsicher)"
> - **Firefox:** „Erweitert…" → „Risiko akzeptieren und fortfahren"
> - **Safari:** „Details einblenden" → „Diese Website besuchen"
>
> Die Warnung erscheint sowohl für das Frontend (Port 443) als auch für die Backend-API (Port 453) – beide müssen einmalig bestätigt werden.

### Nützliche Befehle

```bash
# Backend neu starten
sudo systemctl restart solarmanager.service

# Backend-Status prüfen
sudo systemctl status solarmanager.service

# Backend-Logs anzeigen
sudo journalctl -u solarmanager.service -f
```
