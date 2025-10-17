#!/bin/bash
# Wersja 2.0 - Architektura z automatyczną aktualizacją GeoIP

# ZATRZYMAJ SKRYPT PRZY PIERWSZYM BŁĘDZIE - kluczowe dla stabilności i debugowania.
set -e

# Przekierowuje całe wyjście skryptu do pliku logu.
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

# ===================================================================
# SEKCJA 1: ZMIENNE KONFIGURACYJNE
# ===================================================================
echo "--- [ETAP 1/7] Definiowanie zmiennych konfiguracyjnych ---"

# === Zmienne Użytkownika ===
GRAFANA_ADMIN_PASSWORD="SuperTajneHaslo123!"
# Dane do usługi GeoIP Update - zdobądź je za darmo z: https://www.maxmind.com/en/geolite2/signup
# WAŻNE: Uzupełnij swoje dane!
GEOIPUPDATE_ACCOUNT_ID="TWOJE_ID_KONTA_MAXMIND"
GEOIPUPDATE_LICENSE_KEY="TWOJ_KLUCZ_LICENCYJNY_MAXMIND"

# === Wersje Oprogramowania ===
DOCKER_COMPOSE_VERSION="v2.23.0"
COWRIE_IMAGE="cowrie/cowrie:latest"
LOKI_IMAGE="grafana/loki:2.9.2"
PROMTAIL_IMAGE="grafana/promtail:2.9.2"
GRAFANA_IMAGE="grafana/grafana:10.1.5"
GEOIPUPDATE_IMAGE="ghcr.io/maxmind/geoipupdate:latest"

# === Ścieżki ===
HONEYPOT_DIR="/opt/honeypot"
COWRIE_DIR="$HONEYPOT_DIR/cowrie"
PROMTAIL_DIR="$HONEYPOT_DIR/promtail"
LOKI_DIR="$HONEYPOT_DIR/loki"
GRAFANA_DIR="$HONEYPOT_DIR/grafana"
PCAP_DIR="$HONEYPOT_DIR/pcap_data"

# ===================================================================
# SEKCJA 2: PRZYGOTOWANIE SYSTEMU
# ===================================================================
echo "--- [ETAP 2/7] Aktualizacja systemu i instalacja podstawowych narzędzi ---"
apt-get update
apt-get upgrade -y
apt-get install -y apt-transport-https ca-certificates curl software-properties-common iptables-persistent tcpdump

echo "--- Tworzenie struktury katalogów dla konfiguracji ---"
mkdir -p $COWRIE_DIR/etc $COWRIE_DIR/var/lib
mkdir -p $PROMTAIL_DIR
mkdir -p $LOKI_DIR
mkdir -p $GRAFANA_DIR/provisioning/datasources
mkdir -p $PCAP_DIR

# ===================================================================
# SEKCJA 3: INSTALACJA DOCKERA
# ===================================================================
echo "--- [ETAP 3/7] Instalacja silnika kontenerów Docker CE i Docker Compose ---"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io

curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
echo "Zainstalowano Docker i Docker Compose"

# ===================================================================
# SEKCJA 4: GENEROWANIE PLIKÓW KONFIGURACYJNYCH
# ===================================================================
echo "--- [ETAP 4/7] Generowanie plików konfiguracyjnych dla stosu Docker ---"

# Plik docker-compose.yml definiuje wszystkie nasze usługi, sieci i woluminy.
cat <<EOF > $HONEYPOT_DIR/docker-compose.yml
version: '3.7'

# Definicja współdzielonego woluminu dla bazy GeoIP
volumes:
  geoip_data:

services:
  # Usługa 1: Cowrie - właściwy honeypot.
  cowrie:
    image: ${COWRIE_IMAGE}
    container_name: cowrie
    volumes:
      - $COWRIE_DIR/etc:/cowrie/etc
      - $COWRIE_DIR/var/lib:/cowrie/var/lib/cowrie
    ports:
      - "2222:2222"
      - "2223:2223"
    restart: unless-stopped

  # Usługa 2: GeoIP Update - automatycznie aktualizuje bazę GeoIP.
  geoipupdate:
    image: ${GEOIPUPDATE_IMAGE}
    container_name: geoipupdate
    restart: always
    environment:
      - GEOIPUPDATE_ACCOUNT_ID=${GEOIPUPDATE_ACCOUNT_ID}
      - GEOIPUPDATE_LICENSE_KEY=${GEOIPUPDATE_LICENSE_KEY}
      - 'GEOIPUPDATE_EDITION_IDS=GeoLite2-City'
      - GEOIPUPDATE_FREQUENCY=72 # Aktualizuj co 3 dni
    volumes:
      - geoip_data:/usr/share/GeoIP # Zapisuje bazę do współdzielonego woluminu

  # Usługa 3: Loki - system do agregacji i przechowywania logów.
  loki:
    image: ${LOKI_IMAGE}
    container_name: loki
    volumes:
      - $LOKI_DIR:/etc/loki
    command: -config.file=/etc/loki/loki-config.yml
    ports:
      - "3100:3100"
    restart: unless-stopped

  # Usługa 4: Promtail - agent zbierający logi.
  promtail:
    image: ${PROMTAIL_IMAGE}
    container_name: promtail
    depends_on:
      - geoipupdate # Upewnij się, że wolumin jest gotowy
    volumes:
      - $COWRIE_DIR/var/lib:/var/log/cowrie:ro
      - $PROMTAIL_DIR/promtail.yml:/etc/promtail/promtail.yml:ro
      - geoip_data:/usr/share/GeoIP:ro # Odczytuje bazę ze współdzielonego woluminu
    command: -config.file=/etc/promtail/promtail.yml
    restart: unless-stopped

  # Usługa 5: Grafana - narzędzie do wizualizacji.
  grafana:
    image: ${GRAFANA_IMAGE}
    container_name: grafana
    volumes:
      - $GRAFANA_DIR/data:/var/lib/grafana
      - $GRAFANA_DIR/provisioning:/etc/grafana/provisioning
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
    ports:
      - "3000:3000"
    restart: unless-stopped
EOF

cat <<EOF > $LOKI_DIR/loki-config.yml
auth_enabled: false
server:
  http_listen_port: 3100
ingester:
  lifecycler:
    address: 127.0.0.1
    ring:
      kvstore:
        store: inmemory
      replication_factor: 1
    final_sleep: 0s
  chunk_idle_period: 5m
  chunk_retain_period: 1m
schema_config:
  configs:
    - from: 2020-05-15
      store: boltdb
      object_store: filesystem
      schema: v11
      index:
        prefix: index_
        period: 168h
storage_config:
  boltdb:
    directory: /tmp/loki/index
  filesystem:
    directory: /tmp/loki/chunks
EOF

# Konfiguracja Promtail z zaawansowanym potokiem i nową ścieżką do bazy GeoIP.
cat <<EOF > $PROMTAIL_DIR/promtail.yml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
- job_name: cowrie
  static_configs:
  - targets:
      - localhost
    labels:
      job: cowrie
      __path__: /var/log/cowrie/cowrie.json*
  pipeline_stages:
  - json:
      expressions:
        timestamp: timestamp
        src_ip: src_ip
  - timestamp:
      source: timestamp
      format: RFC3339Nano
  - geoip:
      db: /usr/share/GeoIP/GeoLite2-City.mmdb # Nowa ścieżka do bazy w woluminie
      source: src_ip
EOF

cat <<EOF > $GRAFANA_DIR/provisioning/datasources/loki.yml
apiVersion: 1
datasources:
- name: Loki
  type: loki
  access: proxy
  url: http://loki:3100
  isDefault: true
  jsonData:
    maxLines: 1000
EOF
echo "Pliki konfiguracyjne wygenerowane."

# ===================================================================
# SEKCJA 5: KONFIGURACJA SIECI I ZABEZPIECZEŃ
# ===================================================================
echo "--- [ETAP 5/7] Konfiguracja sieci i zmiana portu SSH ---"
sed -i 's/^#\?Port 22/Port 22222/' /etc/ssh/sshd_config
systemctl restart sshd || { echo "KRYTYCZNY BŁĄD: Nie udało się zrestartować usługi SSHD po zmianie portu!"; exit 1; }
echo "Port systemowy SSH zmieniony na 22222."

sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

iptables -t nat -A PREROUTING -p tcp --dport 22 -j REDIRECT --to-port 2222
iptables -t nat -A PREROUTING -p tcp --dport 23 -j REDIRECT --to-port 2223
iptables-save > /etc/iptables/rules.v4
echo "Reguły iptables do przekierowania ruchu na honeypot zostały ustawione."

# ===================================================================
# SEKCJA 6: KONFIGURACJA TCPDUMP JAKO USŁUGI
# ===================================================================
echo "--- [ETAP 6/7] Konfiguracja tcpdump jako usługi systemd ---"
cat <<EOF > /etc/systemd/system/tcpdump-honeypot.service
[Unit]
Description=TCPDump Honeypot Packet Capture
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/tcpdump -i any -w $PCAP_DIR/capture_%%Y-%%m-%%d_%%H-%%M-%%S.pcap -G 3600 -C 100 -Z root 'port 22 or port 23'
Restart=always
RestartSec=5
CPUQuota=50%
MemoryMax=500M

[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now tcpdump-honeypot.service
echo "Usługa tcpdump skonfigurowana i uruchomiona."

# ===================================================================
# SEKCJA 7: URUCHOMIENIE STOSU APLIKACJI
# ===================================================================
echo "--- [ETAP 7/7] Uruchamianie kontenerów Docker ---"
/usr/local/bin/docker-compose -f $HONEYPOT_DIR/docker-compose.yml up -d

echo "--- Konfiguracja serwera Honeypot zakończona pomyślnie! Sprawdź logi w /var/log/user-data.log ---"

