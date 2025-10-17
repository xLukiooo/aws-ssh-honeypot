# Projekt Honeypot BSK2 (Automatyczne Wdrożenie na AWS)

## 1. Cel Projektu

Celem tego projektu jest stworzenie w pełni zautomatyzowanego, gotowego do wdrożenia systemu honeypot na platformie AWS. System wykorzystuje **Cowrie** do emulacji usług SSH i Telnet, aby przyciągać, przechwytywać i analizować próby nieautoryzowanego dostępu.

Cała infrastruktura jest definiowana jako kod (IaC) za pomocą **Terraform**, a konfiguracja serwera odbywa się automatycznie przez skrypt `user_data`. Stos oprogramowania do analizy (Loki, Promtail, Grafana) działa w kontenerach **Docker**, zapewniając izolację i łatwość zarządzania.

Projekt jest przeznaczony do celów edukacyjnych i badawczych, umożliwiając obserwację i analizę wektorów ataków w czasie rzeczywistym.

## 2. Kluczowe Cechy

- **Pełna Automatyzacja:** Wdrożenie całego systemu za pomocą jednego polecenia `terraform apply`.
- **Infrastruktura jako Kod (IaC):** Powtarzalne i wersjonowane środowisko dzięki Terraform.
- **Stos Dockerowy:** Wszystkie usługi (Cowrie, Loki, Promtail, Grafana) są skonteneryzowane, co ułatwia zarządzanie i izoluje zależności.
- **Analiza w Czasie Rzeczywistym:** Interaktywny dashboard w Grafanie do wizualizacji danych o atakach.
- **Geolokalizacja Ataków:** Automatyczne wzbogacanie logów o dane geograficzne na podstawie adresu IP atakującego (dzięki Promtail i bazie GeoLite2).
- **Głęboka Analiza Pakietów:** Usługa `tcpdump` w tle przechwytuje cały ruch na portach honeypota do późniejszej analizy w Wireshark.
- **Bezpieczeństwo:** Dostęp administracyjny do serwera jest ograniczony do konkretnego adresu IP, a panel Grafany jest chroniony za pomocą tunelu SSH.

## 3. Jak to Działa? Architektura i Przepływ Danych

System składa się z kilku współpracujących ze sobą komponentów. Poniżej przedstawiono przepływ danych od momentu ataku do jego wizualizacji.

![Diagram Architektury](https://i.imgur.com/YOUR_DIAGRAM_URL.png)  <!-- Możesz stworzyć i wstawić tu link do diagramu -->

**Krok 1: Provisioning Infrastruktury (Terraform)**
1.  Użytkownik uruchamia `terraform apply`.
2.  Terraform komunikuje się z API AWS i tworzy następujące zasoby:
    - **Instancja EC2:** Maszyna wirtualna z systemem Ubuntu 22.04 LTS.
    - **Grupa Bezpieczeństwa:** Firewall skonfigurowany tak, aby:
        - Zezwalać na ruch przychodzący z całego świata na porty **22 (SSH)** i **23 (Telnet)** - to są nasze "pułapki".
        - Zezwalać na ruch na port **22222 (zarządzanie SSH)** wyłącznie z adresu IP użytkownika.
        - Blokować wszelki inny ruch przychodzący (w tym na port Grafany **3000**).
    - **Para Kluczy SSH:** Do bezpiecznego logowania na serwer.

**Krok 2: Automatyczna Konfiguracja (Skrypt `user_data.sh`)**
Gdy instancja EC2 uruchamia się po raz pierwszy, wykonuje skrypt `user_data.sh`, który:
1.  Aktualizuje system i instaluje niezbędne pakiety (`docker`, `docker-compose`, `tcpdump`, `iptables-persistent`).
2.  Pobiera bazę danych **GeoLite2** od MaxMind, niezbędną do geolokalizacji.
3.  **Dynamicznie generuje pliki konfiguracyjne** (`docker-compose.yml`, `promtail-config.yml`, `loki-config.yml`) bezpośrednio na serwerze.
4.  **Zmienia port systemowej usługi SSH z 22 na 22222**, aby zwolnić domyślny port dla honeypota.
5.  Konfiguruje **`iptables`** do przekierowania całego ruchu z publicznych portów `22` i `23` na wewnętrzne porty kontenera Cowrie (`2222` i `2223`).
6.  Uruchamia **`tcpdump`** jako usługę `systemd`, która w tle zapisuje ruch sieciowy do plików `.pcap`.
7.  Na końcu uruchamia cały stos aplikacji za pomocą `docker-compose up -d`.

**Krok 3: Atak i Przechwycenie Danych (Cowrie)**
1.  Atakujący skanuje internet i znajduje otwarte porty 22/23 na publicznym IP naszej instancji.
2.  `iptables` transparentnie przekierowuje jego połączenie do kontenera **Cowrie**.
3.  Cowrie emuluje serwer SSH/Telnet i zapisuje wszystkie interakcje (próby logowania, wpisywane komendy, przesyłane pliki) do pliku `cowrie.json`.

**Krok 4: Agregacja i Wizualizacja (Promtail -> Loki -> Grafana)**
1.  **Promtail** monitoruje plik `cowrie.json`.
2.  Gdy pojawia się nowy wpis, Promtail:
    - Odczytuje go.
    - Wyciąga adres IP atakującego (`src_ip`).
    - Używa bazy **GeoLite2**, aby dodać do logu informacje o kraju, mieście i współrzędnych geograficznych.
    - Wysyła wzbogacony log do **Loki**.
3.  **Loki** agreguje i indeksuje logi, udostępniając je do zapytań.
4.  **Grafana**, połączona z Loki jako źródłem danych, wykonuje zapytania (np. "pokaż liczbę ataków z podziałem na kraje") i wizualizuje wyniki na dashboardzie w postaci map, wykresów i tabel.

## 4. Struktura Projektu

```
.
├── main.tf                # Główny plik Terraform definiujący infrastrukturę AWS
├── user_data.sh           # Skrypt do automatycznej konfiguracji instancji EC2
├── README.md              # Ten plik
└── projekt-bsk2-key.pem   # Klucz prywatny SSH pobrany z AWS (NIE WYSYŁAJ GO DO GIT!)
```

## 5. Wymagania

Przed rozpoczęciem upewnij się, że masz:
1.  Konto w **AWS**.
2.  Zainstalowane i skonfigurowane **AWS CLI** z poświadczeniami dostępowymi.
3.  Zainstalowany **Terraform** (wersja 1.0.0 lub nowsza).
4.  **Klucz licencyjny i ID konta MaxMind GeoLite2**. Można je uzyskać za darmo po rejestracji na [stronie MaxMind](https://www.maxmind.com/en/geolite2/signup).

## 6. Instrukcja Uruchomienia

1.  **Sklonuj to repozytorium lub pobierz pliki**.

2.  **Stwórz parę kluczy SSH w konsoli AWS**:
    - Zaloguj się do konsoli AWS i przejdź do usługi **EC2**.
    - W menu po lewej stronie znajdź `Network & Security` -> `Key Pairs`.
    - Kliknij `Create key pair`.
    - Wpisz nazwę: **`projekt-bsk2-key`** (musi być dokładnie taka nazwa!).
    - Wybierz format klucza prywatnego: `pem`.
    - Kliknij `Create key pair` i pobierz plik `projekt-bsk2-key.pem`.
    - **Umieść pobrany plik `projekt-bsk2-key.pem` w głównym katalogu projektu**.

3.  **Edytuj plik `user_data.sh`**:
    - Wklej swoje ID konta i klucz licencyjny MaxMind w zmiennych `GEOIPUPDATE_ACCOUNT_ID` i `GEOIPUPDATE_LICENSE_KEY`.
    - (Opcjonalnie) Zmień hasło administratora Grafany w zmiennej `GRAFANA_ADMIN_PASSWORD`.

4.  **Zainicjuj Terraform**:
    ```bash
    terraform init
    ```

5.  **Wdróż infrastrukturę**:
    ```bash
    terraform apply -auto-approve
    ```
    Po kilku minutach Terraform wyświetli publiczny adres IP instancji oraz gotowe komendy do połączenia.

## 7. Dostęp i Analiza Danych

1.  **Stwórz tunel SSH do Grafany** (komenda zostanie wyświetlona na wyjściu `terraform apply`):
    ```bash
    ssh -i projekt-bsk2-key.pem -L 3000:localhost:3000 -p 22222 ubuntu@<PUBLICZNE_IP>
    ```
2.  Otwórz przeglądarkę i wejdź na `http://localhost:3000`.
3.  Zaloguj się do Grafany (użytkownik: `admin`, hasło: to, które ustawiłeś w skrypcie).
4.  Zaimportuj gotowy dashboard, podając ID `23141` w sekcji `Dashboards -> Import`.
5.  Pobierz pliki z przechwyconym ruchem (`.pcap`) za pomocą `scp` do analizy w Wireshark (komenda również na wyjściu `terraform apply`):
    ```bash
    scp -i projekt-bsk2-key.pem -P 22222 "ubuntu@<PUBLICZNE_IP>:/opt/honeypot/pcap_data/*.pcap" .
    ```

## 8. Usuwanie Infrastruktury

Aby usunąć wszystkie zasoby stworzone w AWS i uniknąć kosztów, wykonaj polecenie:
```bash
terraform destroy -auto-approve
```