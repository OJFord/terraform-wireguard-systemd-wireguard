output "local_peer_conf" {
  description = "WireGuard config file for the `var.local_peer`, if configured"
  value       = local.local_peer_conf
  sensitive   = true

  depends_on = [
    null_resource.wireguard,
  ]
}
