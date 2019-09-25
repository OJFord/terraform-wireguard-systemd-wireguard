output "local_peer_conf" {
  description = "WireGuard config file for the `var.local_peer`, if configured"
  value       = local.configure_local_peer ? local_file.local_peer_conf[0].sensitive_content : null
  sensitive   = true
}
