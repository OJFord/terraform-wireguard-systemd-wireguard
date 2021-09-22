output "spoke_peer_confs" {
  description = "Public keys and config files for the `var.spoke_peers`, if configured"
  value       = local.spokes
  sensitive   = true

  depends_on = [
    null_resource.wireguard,
  ]
}
