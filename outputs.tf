output "local_peer_conf" {
  description = "WireGuard config file for the `var.local_peer`, if configured"
  value       = local.configure_local_peer ? data.local_file.local_peer_conf.content : null
  sensitive   = true
}
