#!/bin/bash
# Wersja 5.0 - VictoriaLogs zamiast Loki + GeoIP

set -e
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

# KONFIGURACJA ZMIENNYCH
GRAFANA_ADMIN_PASSWORD="SuperTajneHaslo123!"
GEOIPUPDATE_ACCOUNT_ID="TWOJE_ID_KONTA_MAXMIND"
GEOIPUPDATE_LICENSE_KEY="TWOJ_KLUCZ_LICENCYJNY_MAXMIND"
DOCKER_COMPOSE_VERSION="v2.23.0"
COWRIE_IMAGE="cowrie/cowrie:latest"
VICTORIALOGS_IMAGE="victoriametrics/victoria-logs:latest"
PROMTAIL_IMAGE="grafana/promtail:2.9.2"
GRAFANA_IMAGE="grafana/grafana:10.1.5"
GEOIPUPDATE_IMAGE="ghcr.io/maxmind/geoipupdate:latest"
HONEYPOT_DIR="/opt/honeypot"
PROMTAIL_DIR="$HONEYPOT_DIR/promtail"
VICTORIALOGS_DIR="$HONEYPOT_DIR/victorialogs"
GRAFANA_DIR="$HONEYPOT_DIR/grafana"
PCAP_DIR="$HONEYPOT_DIR/pcap_data"

echo "=== SEKCJA 2: Przygotowanie systemu ==="
apt-get update
apt-get upgrade -y
# Pre-konfiguruj odpowiedzi dla iptables-persistent (aby uniknąć interaktywnego promptu)
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections

# Instalacja pakietów w trybie nieinteraktywnym
DEBIAN_FRONTEND=noninteractive apt-get install -y apt-transport-https ca-certificates curl software-properties-common iptables-persistent tcpdump

mkdir -p $PROMTAIL_DIR
mkdir -p $VICTORIALOGS_DIR
mkdir -p $GRAFANA_DIR/provisioning/datasources $GRAFANA_DIR/data
mkdir -p $PCAP_DIR

echo "=== SEKCJA 3: Instalacja Dockera ==="
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io
curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

echo "=== SEKCJA 4: Generowanie plików konfiguracyjnych ==="

cat <<EOF > $HONEYPOT_DIR/docker-compose.yml
version: '3.7'

volumes:
  geoip_data:
  cowrie-log:
  cowrie-data:
  victorialogs-data:

services:
  cowrie:
    image: cowrie/cowrie:latest
    container_name: cowrie
    volumes:
      - cowrie-log:/cowrie/cowrie-git/var/log/cowrie
      - cowrie-data:/cowrie/cowrie-git/var/lib/cowrie
    ports:
      - "2222:2222/tcp"
      - "2223:2223/tcp"
    restart: unless-stopped

  geoipupdate:
    image: ghcr.io/maxmind/geoipupdate:latest
    container_name: geoipupdate
    restart: always
    environment:
      - GEOIPUPDATE_ACCOUNT_ID=${GEOIPUPDATE_ACCOUNT_ID}
      - GEOIPUPDATE_LICENSE_KEY=${GEOIPUPDATE_LICENSE_KEY}
      - GEOIPUPDATE_EDITION_IDS=GeoLite2-ASN GeoLite2-City GeoLite2-Country
      - GEOIPUPDATE_FREQUENCY=72
    volumes:
      - geoip_data:/usr/share/GeoIP
    healthcheck:
      test: ["CMD", "test", "-f", "/usr/share/GeoIP/GeoLite2-City.mmdb"]
      interval: 30s
      timeout: 10s
      retries: 5

  victorialogs:
    image: victoriametrics/victoria-logs:latest
    container_name: victorialogs
    volumes:
      - victorialogs-data:/victoria-logs-data
    ports:
      - "9428:9428"
    command:
      - "-storageDataPath=/victoria-logs-data"
      - "-httpListenAddr=:9428"
    restart: unless-stopped

  promtail:
    image: grafana/promtail:2.9.2
    container_name: promtail
    depends_on:
      geoipupdate:
        condition: service_healthy
    volumes:
      - cowrie-log:/var/log/cowrie:ro
      - ./promtail/promtail.yml:/etc/promtail/promtail.yml:ro
      - geoip_data:/usr/share/GeoIP:ro
    command: -config.file=/etc/promtail/promtail.yml
    restart: unless-stopped

  grafana:
    image: grafana/grafana:10.1.5
    container_name: grafana
    volumes:
      - ./grafana/data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
      - GF_INSTALL_PLUGINS=victoriametrics-logs-datasource
    ports:
      - "3000:3000"
    restart: unless-stopped
EOF

echo "docker-compose.yml wygenerowany."

# KONFIG PROMTAIL z GeoIP
cat <<EOF > $PROMTAIL_DIR/promtail.yml
server:
  http_listen_port: 9080
  grpc_listen_port: 0
  log_level: warn

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://victorialogs:9428/insert/loki/api/v1/push?_msg_field=message&_stream_fields=instance,job

scrape_configs:
  - job_name: cowrie
    static_configs:
      - targets:
          - localhost
        labels:
          job: cowrie
          __path__: /var/log/cowrie/*.json
          instance: cowrie-promtail
    pipeline_stages:
      - json:
          expressions:
            timestamp: timestamp
            src_ip: src_ip
            session: session
            message: message
            eventid: eventid
      - timestamp:
          source: timestamp
          format: RFC3339Nano
      - geoip:
          db: /usr/share/GeoIP/GeoLite2-City.mmdb
          source: src_ip
          db_type: "city"
          output:
            geoip_country: country.iso_code
            geoip_city: city.names.en
            geoip_latitude: location.latitude
            geoip_longitude: location.longitude
      - labels:
          src_ip:
          session:
          geoip_country:
          geoip_city:
          geoip_latitude:
          geoip_longitude:
EOF

# KONFIG GRAFANA dla VictoriaLogs
cat <<EOF > $GRAFANA_DIR/provisioning/datasources/victorialogs.yml
apiVersion: 1
datasources:
- name: VictoriaLogs
  type: victoriametrics-logs-datasource
  access: proxy
  url: http://victorialogs:9428
  isDefault: true
  jsonData:
    maxLines: 1000
  editable: true
EOF

# ZMIANA PORTU SSH
sed -i '/^#*Port /d' /etc/ssh/sshd_config
echo "Port 22222" >> /etc/ssh/sshd_config
systemctl restart sshd || { echo "KRYTYCZNY BŁĄD: Nie udało się zrestartować usługi SSHD po zmianie portu!"; exit 1; }

sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
iptables -t nat -A PREROUTING -p tcp --dport 22 -j REDIRECT --to-port 2222
iptables -t nat -A PREROUTING -p tcp --dport 23 -j REDIRECT --to-port 2223

iptables -t nat -L PREROUTING -n -v

cat <<EOF > /etc/systemd/system/tcpdump-honeypot.service
[Unit]
Description=TCPDump Honeypot Packet Capture
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/tcpdump -i any -w /opt/honeypot/pcap_data/capture.pcap -G 3600 -C 100 -Z root port 22 or port 23
Restart=always
RestartSec=5
CPUQuota=50%
MemoryMax=500M

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now tcpdump-honeypot.service

# SKRYPT CZYSZCZĄCY DANE COWRIE
CLEAN_SCRIPT="/usr/local/bin/cowrie_cleanup.sh"
cat << 'CLEANUP_EOF' > "$CLEAN_SCRIPT"
#!/bin/bash
# Czyszczenie starych plików pobranych przez Cowrie
VOLUME_NAME="honeypot_cowrie-data"
docker run --rm -v ${VOLUME_NAME}:/data alpine sh -c '
  find /data/downloads -type f -size +10M -delete 2>/dev/null || true
  TOTAL=$(find /data/downloads -type f 2>/dev/null | wc -l)
  if [ "$TOTAL" -gt 100 ]; then
    find /data/downloads -type f -printf "%T@ %p\n" | sort -n | head -n -100 | cut -d" " -f2- | xargs rm -f
  fi
'
CLEANUP_EOF
chmod +x "$CLEAN_SCRIPT"
echo "0 2 * * * root $CLEAN_SCRIPT" >> /etc/crontab

chown -R 472:472 $GRAFANA_DIR/data
chown -R 472:472 $GRAFANA_DIR/provisioning
chown -R root:root $PROMTAIL_DIR
chown -R root:root $PCAP_DIR
chmod -R 755 $HONEYPOT_DIR
chmod -R 755 $PROMTAIL_DIR
chmod -R 755 $VICTORIALOGS_DIR

sleep 2
cd $HONEYPOT_DIR
docker pull $COWRIE_IMAGE
docker pull $VICTORIALOGS_IMAGE
docker pull $PROMTAIL_IMAGE
docker pull $GRAFANA_IMAGE
docker pull $GEOIPUPDATE_IMAGE

/usr/local/bin/docker-compose down 2>/dev/null || true
sleep 3
/usr/local/bin/docker-compose up -d
sleep 20

docker ps | grep cowrie || { echo "KRYTYCZNY BŁĄD: Kontener Cowrie nie uruchomił się poprawnie!"; exit 1; }
echo "Kontenery uruchomione pomyślnie:"
docker ps

echo "=== Sprawdzanie logów Cowrie ==="
docker logs cowrie --tail 30

echo "=== Sprawdzanie logów Promtail ==="
docker logs promtail --tail 20

echo "=== Sprawdzanie logów VictoriaLogs ==="
docker logs victorialogs --tail 20

iptables -A OUTPUT -p tcp --dport 25 ! -d 127.0.0.1 -j DROP
iptables-save > /etc/iptables/rules.v4

echo "========================================="
echo "=== KONFIGURACJA HONEYPOT ZAKOŃCZONA ==="
echo "========================================="
echo ""
echo "Dostęp do usług:"
echo "  - Grafana: http://<IP>:3000 (admin / $GRAFANA_ADMIN_PASSWORD)"
echo "  - VictoriaLogs: http://<IP>:9428"
echo "  - SSH Honeypot: port 22 => 2222"
echo "  - Telnet Honeypot: port 23 => 2223"
echo "  - Prawdziwy SSH: port 22222"
echo "  - PCAP: $PCAP_DIR"
echo ""
echo "WAŻNE: Aby wygenerować logi, przetestuj honeypot:"
echo "  ssh root@192.168.10.90 -p 22 (będzie przekierowane na 2222)"
echo "  lub: ssh root@localhost -p 2222"
echo "  Domyślne hasła: root, password, 123456"
echo ""
echo "Sprawdzenie logów Cowrie:"
echo "  sudo docker logs cowrie"
echo "  sudo docker cp cowrie:/cowrie/cowrie-git/var/log/cowrie /tmp/cowrie_logs"
echo "  ls -lh /tmp/cowrie_logs/"
echo "  cat /tmp/cowrie_logs/cowrie.json | tail -20"
echo ""
echo "Weryfikacja sesji TTY z honeypota:"
echo "  sudo docker cp cowrie:/cowrie/cowrie-git/var/lib/cowrie/tty /tmp/cowrie_tty"
echo "  ls -lh /tmp/cowrie_tty/"
echo ""
echo "UWAGA: W Grafanie musisz zainstalować plugin VictoriaLogs datasource"
echo "  lub dodać go ręcznie z: https://grafana.com/grafana/plugins/victoriametrics-logs-datasource/"
