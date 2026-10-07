output "honeypot_public_ip" {
  value       = aws_instance.honeypot_instance.public_ip
  description = "Publiczny adres IP serwera honeypot"
}

output "ssh_management_command" {
  value       = "ssh -i ${var.key_name}.pem -p 22222 ubuntu@${aws_instance.honeypot_instance.public_ip}"
  description = "Polecenie bezpiecznego logowania do serwera przez SSH"
}

output "grafana_tunnel_command" {
  value       = "ssh -i ${var.key_name}.pem -L 3000:localhost:3000 -p 22222 ubuntu@${aws_instance.honeypot_instance.public_ip}"
  description = "Tunel SSH do panelu Grafana (dostęp na http://localhost:3000)"
}

output "tcpdump_download_command" {
  value       = "scp -i ${var.key_name}.pem -P 22222 ubuntu@${aws_instance.honeypot_instance.public_ip}:/opt/honeypot/pcap_data/capture*.pcap ."
  description = "Pobranie plikow z surowym ruchem sieciowym PCAP do analizy w Wireshark"
}

output "honeypot_ssh_test_command" {
  value       = "ssh root@${aws_instance.honeypot_instance.public_ip}"
  description = "Polecenie do przetestowania pulapki honeypota jako atakujacy"
}
