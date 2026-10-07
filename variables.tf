variable "aws_region" {
  description = "Region AWS do wdrożenia infrastruktury."
  type        = string
  default     = "us-east-1"
}

variable "key_name" {
  description = "Nazwa pary kluczy SSH w AWS EC2 do zarządzania serwerem."
  type        = string
  default     = "honeypot-key"
}

variable "grafana_admin_password" {
  description = "Hasło administratora do panelu Grafana."
  type        = string
  sensitive   = true
}

variable "geoipupdate_account_id" {
  description = "Account ID konta MaxMind GeoIP Update."
  type        = string
  sensitive   = true
}

variable "geoipupdate_license_key" {
  description = "Klucz licencyjny MaxMind GeoIP Update."
  type        = string
  sensitive   = true
}

variable "docker_compose_version" {
  description = "Wersja Docker Compose do zainstalowania."
  type        = string
  default     = "v2.23.0"
}