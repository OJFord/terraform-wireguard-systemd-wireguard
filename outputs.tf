output "local_peer_conf" {
  description = "WireGuard config file for the `var.local_peer`, if configured"
  value       = local.configure_local_peer ? file(local.local_peer_conf_file) : null
  sensitive   = true
}
