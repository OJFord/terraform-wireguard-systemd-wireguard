locals {
  peer_idx = toset(range(length(var.peers)))
  peers    = { for idx in local.peer_idx : idx => var.peers[idx] }

  keyfile = var.key_filename
  pubfile = "${local.keyfile}.pub"

  configure_local_peer = var.local_peer.internal_ip != ""
  local_peer_dir       = "${path.module}/.local-peer"

  local_peer_conf = local.configure_local_peer ? null : <<EOC
    [Interface]
    Address=${var.local_peer.internal_ip}/${var.mesh_prefix}
    ListenPort=${var.local_peer.port}
    PrivateKey=${wireguard_asymmetric_key.local_peer[0].private_key}

  %{for peer in local.peers}
    [Peer]
    PublicKey=${wireguard_asymmetric_key.remote_peer[index(local.peers, peer)].public_key}
    AllowedIPs=${peer.internal_ip}/32
  %{if peer.endpoint != ""}
    Endpoint=${peer.endpoint}:${peer.port}
  %{endif}
  %{endfor}
EOC
}

resource "null_resource" "systemd_conf" {
  for_each = var.use_extant_systemd_conf ? {} : local.peers

  provisioner "file" {
    content     = <<EOC
      [Match]
      Name=${var.interface}
EOC
    destination = "${var.systemd_dir}/${var.interface}.network"
  }

  provisioner "file" {
    content     = <<EOC
      [NetDev]
      Name=${var.interface}
      Kind=wireguard
      Description=WireGuard

      [WireGuard]
      ListenPort=${each.value.port}
      PrivateKeyFile=${var.key_filename}
EOC
    destination = "${var.systemd_dir}/${var.interface}.netdev"
  }
}

resource "null_resource" "address" {
  for_each = local.peers

  triggers = {
    id     = each.value.id
    ip     = each.value.internal_ip
    prefix = var.mesh_prefix
    iface  = var.interface
  }

  connection {
    host = each.value.ssh_host
    user = each.value.ssh_user
  }

  provisioner "file" {
    content     = <<EOC
      [Network]
      Address=${each.value.internal_ip}/${var.mesh_prefix}
EOC
    destination = "${var.systemd_dir}/${var.interface}.network.d/address.conf"
  }
}

resource "wireguard_asymmetric_key" "remote_peer" {
  for_each = local.peers
}

resource "null_resource" "keys" {
  for_each = wireguard_asymmetric_key.remote_peer

  connection {
    host = local.peers[each.index].ssh_host
    user = local.peers[each.index].ssh_user
  }

  provisioner "file" {
    content     = each.value.private_key
    destination = local.keyfile
  }

  provisioner "file" {
    content     = each.value.public_key
    destination = local.pubfile
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 0640 '${local.keyfile}'",
      "chown root:systemd-network '${local.keyfile}'",
      "chmod 0644 '${local.pubfile}'",
    ]
  }
}

resource "wireguard_asymmetric_key" "local_peer" {
  count = local.configure_local_peer ? 1 : 0
}

resource "null_resource" "peers" {
  for_each = local.peers

  triggers = {
    hostnames    = md5(join("", [for p in local.peers : p.hostname]))
    internal_ips = md5(join("", [for p in local.peers : p.internal_ip]))
    keys         = md5(join("", [for k in null_resource.keys : k.id]))
    endpoints    = md5(join("", [for p in local.peers : p.endpoint]))
    local_peer   = wireguard_asymmetric_key.local_peer[0].id
  }

  connection {
    host = each.value.ssh_host
    user = each.value.ssh_user
  }

  provisioner "file" {
    content     = <<EOC
    %{for peer in local.peers}
      [WireGuardPeer]
      PublicKey=${wireguard_asymmetric_key.remote_peer[index(var.peers, peer)].public_key}

    %{if peer.endpoint != ""}
      Endpoint=${peer.endpoint}:${peer.port}
    %{endif}

    %{if ! each.value.egress && peer.egress}
      AllowedIPs=0.0.0.0/0,::/0
    %{else}
      AllowedIPs=${peer.internal_ip}/32
    %{endif}

    %{endfor}

    %{if local.configure_local_peer}
      [WireGuardPeer]
      PublicKey=${wireguard_asymmetric_key.local_peer[0].public_key}
      AllowedIPs=${var.local_peer.internal_ip}/32
    %{endif}
EOC
    destination = "${var.systemd_dir}/${var.interface}.netdev.d/peers.conf"
  }
}

resource "null_resource" "wireguard" {
  for_each = local.peers

  triggers = {
    addr  = null_resource.address[each.key].id
    key   = null_resource.keys[each.key].id
    peers = null_resource.peers[each.key].id
  }

  depends_on = [
    null_resource.address,
    null_resource.keys,
    null_resource.peers,
  ]

  connection {
    host = each.value.ssh_host
    user = each.value.ssh_user
  }

  provisioner "remote-exec" {
    inline = [
      "systemctl restart systemd-networkd",
    ]
  }
}
