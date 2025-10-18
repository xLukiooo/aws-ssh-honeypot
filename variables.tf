variable "grafana_admin_password" {
  description = "Password for the Grafana admin user."
  type        = string
  sensitive   = true
}

variable "geoipupdate_account_id" {
  description = "MaxMind GeoIP Update Account ID."
  type        = string
  sensitive   = true
}

variable "geoipupdate_license_key" {
  description = "MaxMind GeoIP Update License Key."
  type        = string
  sensitive   = true
}
