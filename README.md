# Projekt Honeypot BSK2 (Automatyczne Wdrożenie na AWS)

## 1. Cel Projektu

Celem tego projektu jest stworzenie w pełni zautomatyzowanego, gotowego do wdrożenia systemu honeypot na platformie AWS. System wykorzystuje **Cowrie** do emulacji usługi SSH, aby przyciągać, przechwytywać i analizować próby nieautoryzowanego dostępu.

Cała infrastruktura jest definiowana jako kod (IaC) za pomocą **Terraform**, a konfiguracja serwera odbywa się automatycznie. Stos oprogramowania do analizy (**VictoriaLogs**, Promtail, Grafana) działa w kontenerach **Docker**, zapewniając izolację i łatwość zarządzania. Sekrety (hasła, klucze API) są zarządzane w bezpieczny sposób za pomocą zmiennych Terraform.

Projekt jest przeznaczony do celów edukacyjnych i badawczych, umożliwiając obserwację i analizę wektorów ataków w czasie rzeczywistym.

## 2. Kluczowe Cechy

- **Pełna Automatyzacja:** Wdrożenie całego systemu za pomocą polecenia `terraform apply`.
- **Infrastruktura jako Kod (IaC):** Powtarzalne i wersjonowane środowisko dzięki Terraform.
- **Bezpieczne Zarządzanie Sekretami:** Hasła i klucze API nie są przechowywane w kodzie, lecz wstrzykiwane w bezpieczny sposób przez Terraform.
- **Stos Dockerowy:** Wszystkie usługi (Cowrie, **VictoriaLogs**, Promtail, Grafana) są skonteneryzowane.
- **Analiza w Czasie Rzeczywistym:** Interaktywny dashboard w Grafanie do wizualizacji danych o atakach.
- **Geolokalizacja Ataków:** Automatyczne wzbogacanie logów o dane geograficzne na podstawie adresu IP atakującego.
- **Głęboka Analiza Pakietów:** Usługa `tcpdump` w tle przechwytuje cały ruch na portach honeypota.
- **Bezpieczeństwo:** Dostęp administracyjny do serwera jest ograniczony do Twojego IP, a panel Grafany jest chroniony za pomocą tunelu SSH.

## 3. Architektura i Przepływ Danych

System składa się z kilku współpracujących ze sobą komponentów.

**Krok 1: Provisioning Infrastruktury (Terraform)**
1.  Użytkownik uzupełnia plik `terraform.tfvars` swoimi sekretami i uruchamia `terraform apply`.
2.  Terraform tworzy w AWS instancję EC2 oraz grupę bezpieczeństwa (firewall), która:
    - Otwiera port **22 (SSH)** na świat (pułapka honeypota).
    - Otwiera port **22222 (zarządzanie SSH)** wyłącznie dla Twojego adresu IP.
    - Blokuje wszelki inny ruch przychodzący.

**Krok 2: Automatyczna Konfiguracja (Skrypt `user_data.tftpl`)**
Gdy instancja EC2 startuje, wykonuje skrypt wygenerowany z szablonu `user_data.tftpl`, który:
1.  Instaluje i konfiguruje wszystkie niezbędne pakiety (`docker`, `docker-compose`, `tcpdump`).
2.  **Wstrzykuje sekrety** (hasło Grafany, klucze MaxMind) przekazane przez Terraform do konfiguracji kontenerów.
3.  Dynamicznie generuje plik `docker-compose.yml` oraz konfiguracje dla pozostałych usług.
4.  Zmienia domyślny port SSH serwera na **22222**.
5.  Konfiguruje `iptables` do przekierowania ruchu z portu 22 na port kontenera Cowrie.
6.  Uruchamia `tcpdump` jako usługę w tle.
7.  Uruchamia cały stos aplikacji za pomocą `docker-compose up -d`.

**Krok 3: Atak i Przechwycenie Danych (Cowrie)**
1.  Atakujący łączy się z portem 22 na publicznym IP serwera.
2.  `iptables` transparentnie przekierowuje jego połączenie do kontenera **Cowrie**.
3.  Cowrie emuluje serwer i zapisuje wszystkie interakcje do logów w formacie JSON.

**Krok 4: Agregacja i Wizualizacja (Promtail -> VictoriaLogs -> Grafana)**
1.  **Promtail** monitoruje logi Cowrie.
2.  Gdy pojawia się nowy wpis, Promtail odczytuje go, wzbogaca o dane **GeoIP** i wysyła do **VictoriaLogs**.
3.  **VictoriaLogs** to wydajna baza danych zoptymalizowana do przechowywania i przeszukiwania logów.
4.  **Grafana** łączy się z VictoriaLogs i wizualizuje dane na dashboardach (mapy, wykresy, tabele).

## 4. Struktura Projektu

```
.
├── main.tf                # Główny plik Terraform definiujący infrastrukturę AWS
├── variables.tf           # Definicje zmiennych (w tym sekretów) dla Terraform
├── user_data.tftpl        # Szablon skryptu do automatycznej konfiguracji instancji EC2
├── .gitignore             # Plik zapobiegający wysyłaniu sekretów i plików stanu do Git
└── README.md              # Ten plik
```

## 5. Wymagania

1.  Konto w **AWS**.
2.  Zainstalowane i skonfigurowane **AWS CLI** z poświadczeniami dostępowymi.
3.  Zainstalowany **Terraform** (wersja 1.1.2 lub nowsza).
4.  **Klucz licencyjny i ID konta MaxMind GeoLite2**. Można je uzyskać za darmo po rejestracji na [stronie MaxMind](https://www.maxmind.com/en/geolite2/signup).

## 6. Instrukcja Uruchomienia

1.  **Sklonuj to repozytorium**.

2.  **Stwórz parę kluczy SSH w konsoli AWS**:
    - Przejdź do usługi **EC2** -> `Key Pairs`.
    - Stwórz nową parę kluczy o nazwie **`projekt-bsk2-key`** w formacie `.pem`.
    - Pobierz plik `projekt-bsk2-key.pem` i umieść go w głównym katalogu projektu.

3.  **Skonfiguruj sekrety**:
    - Stwórz plik `terraform.tfvars`.
    - Otwórz `terraform.tfvars` i uzupełnij go swoimi danymi:
      ```hcl
      grafana_admin_password  = "TWOJE_BARDZO_SILNE_HASLO"
      geoipupdate_account_id  = "TWOJE_ID_KONTA_MAXMIND"
      geoipupdate_license_key = "TWOJ_KLUCZ_LICENCYJNY_MAXMIND"
      ```

4.  **Zainicjuj Terraform**:
    ```bash
    terraform init
    ```

5.  **Wdróż infrastrukturę**:
    ```bash
    terraform apply
    ```
    Po kilku minutach Terraform wyświetli publiczny adres IP instancji oraz gotowe komendy do połączenia.

## 7. Dostęp i Analiza Danych

1.  **Stwórz tunel SSH do Grafany** (komenda zostanie wyświetlona na wyjściu `terraform apply`):
    ```bash
    ssh -i projekt-bsk2-key.pem -L 3000:localhost:3000 -p 22222 ubuntu@<PUBLICZNE_IP>
    ```
2.  Otwórz przeglądarkę i wejdź na `http://localhost:3000`.
3.  Zaloguj się do Grafany (użytkownik: `admin`, hasło: to, które ustawiłeś w pliku `terraform.tfvars`).
4.  Dashboard powinien zostać automatycznie zaimportowany. Jeśli nie, możesz go dodać ręcznie, używając VictoriaLogs jako źródła danych.

5.  Pobierz pliki z przechwyconym ruchem (`.pcap`) za pomocą `scp` (komenda również na wyjściu `terraform apply`):
    ```bash
    scp -i projekt-bsk2-key.pem -P 22222 "ubuntu@<PUBLICZNE_IP>:/opt/honeypot/pcap_data/*.pcap" .
    ```

## 8. Usuwanie Infrastruktury

Aby usunąć wszystkie zasoby stworzone w AWS i uniknąć kosztów, wykonaj polecenie:
```bash
terraform destroy -auto-approve
```
