locals {
  peer_idx = toset(range(length(var.mesh_peers)))
  peers    = { for idx in local.peer_idx : idx => var.mesh_peers[idx] }

  keyfile = var.key_filename
  pubfile = "${local.keyfile}.pub"

  spokes = { for spoke in var.spoke_peers : spoke.alias => {
    internal_ip   = spoke.internal_ip
    public_key    = spoke.public_key != "" ? spoke.public_key : wireguard_asymmetric_key.spoke_peer[spoke.internal_ip].public_key
    systemd_conf  = <<EOC
        [NetDev]
        Name=${var.interface}
        Kind=wireguard
        Description=WireGuard

        [WireGuard]
      %{if spoke.public_key == ""}
        PrivateKey=${wireguard_asymmetric_key.spoke_peer[spoke.internal_ip].private_key}
      %{else}
        PrivateKeyFile=${var.key_filename}
      %{endif}

      %{for peer_idx, peer in local.peers}
        [WireGuardPeer]
        PublicKey=${wireguard_asymmetric_key.remote_peer[peer_idx].public_key}

      %{if peer.endpoint != ""}
        Endpoint=${peer.endpoint}:${peer.port}
      %{endif}

      %{if !spoke.egress && peer.egress}
        AllowedIPs=0.0.0.0/0,::/0
      %{else}
        AllowedIPs=${peer.internal_ip}/32
      %{endif}

      %{endfor}

    EOC
    wg_quick_conf = <<EOC
        [Interface]
        Address=${spoke.internal_ip}/${var.mesh_prefix}
        ListenPort=${spoke.port}
      %{if spoke.public_key == ""}
        PrivateKey=${wireguard_asymmetric_key.spoke_peer[spoke.internal_ip].private_key}
      %{else}
        PrivateKey=# User should replace with that from pre-created key pair with public part: ${spoke.public_key}
      %{endif}

      %{for idx, peer in local.peers}
        [Peer]
        PublicKey=${wireguard_asymmetric_key.remote_peer[idx].public_key}
        AllowedIPs=${peer.internal_ip}/32
      %{if peer.endpoint != ""}
        Endpoint=${peer.endpoint}:${peer.port}
      %{endif}
      %{endfor}
    EOC
  } }
}

resource "null_resource" "systemd_conf" {
  for_each = var.use_extant_systemd_conf ? {} : local.peers

  connection {
    host        = each.value.ssh_host
    user        = each.value.ssh_user
    private_key = each.value.ssh_key
    agent       = each.value.ssh_key == ""
  }

  provisioner "remote-exec" {
    inline = [
      "mkdir -p '${var.systemd_dir}'",
    ]
  }

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
    host        = each.value.ssh_host
    user        = each.value.ssh_user
    private_key = each.value.ssh_key
    agent       = each.value.ssh_key == ""
  }

  provisioner "remote-exec" {
    inline = [
      "mkdir -p '${var.systemd_dir}/${var.interface}.network.d'",
    ]
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
    host        = local.peers[each.key].ssh_host
    user        = local.peers[each.key].ssh_user
    private_key = local.peers[each.key].ssh_key
    agent       = local.peers[each.key].ssh_key == ""
  }

  provisioner "remote-exec" {
    inline = [
      "mkdir -p \"$(dirname '${local.keyfile}')\"",
      "mkdir -p \"$(dirname '${local.pubfile}')\"",
    ]
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

resource "wireguard_asymmetric_key" "spoke_peer" {
  for_each = toset([for s in var.spoke_peers : s.internal_ip if s.public_key == ""])
}

resource "null_resource" "peers" {
  for_each = local.peers

  triggers = {
    hostnames    = md5(join("", [for p in local.peers : p.hostname]))
    internal_ips = md5(join("", [for p in local.peers : p.internal_ip]))
    keys         = md5(join("", [for k in null_resource.keys : k.id]))
    endpoints    = md5(join("", [for p in local.peers : p.endpoint]))
    spokes       = md5(join("", [for s in local.spokes : s.wg_quick_conf]))
  }

  connection {
    host        = each.value.ssh_host
    user        = each.value.ssh_user
    private_key = each.value.ssh_key
    agent       = each.value.ssh_key == ""
  }

  provisioner "remote-exec" {
    inline = [
      "mkdir -p '${var.systemd_dir}/${var.interface}.netdev.d'",
    ]
  }

  provisioner "file" {
    content     = <<EOC
    %{for peer_idx, peer in local.peers}
      [WireGuardPeer]
      PublicKey=${wireguard_asymmetric_key.remote_peer[peer_idx].public_key}

    %{if peer.endpoint != ""}
      Endpoint=${peer.endpoint}:${peer.port}
    %{endif}

    %{if !each.value.egress && peer.egress}
      AllowedIPs=0.0.0.0/0,::/0
    %{else}
      AllowedIPs=${peer.internal_ip}/32
    %{endif}

    %{endfor}

    %{for spoke in local.spokes}
      [WireGuardPeer]
      PublicKey=${spoke.public_key}
      AllowedIPs=${spoke.internal_ip}/32
    %{endfor}
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
    host        = each.value.ssh_host
    user        = each.value.ssh_user
    private_key = each.value.ssh_key
    agent       = each.value.ssh_key == ""
  }

  provisioner "remote-exec" {
    inline = [
      "systemctl restart systemd-networkd",
    ]
  }
}
