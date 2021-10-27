locals {
  peer_idx = toset(range(length(var.mesh_peers)))
  peers    = { for idx in local.peer_idx : idx => var.mesh_peers[idx] }

  keyfile = var.key_filename
  pubfile = "${local.keyfile}.pub"

  spokes = { for spoke in var.spoke_peers : spoke.alias => {
    internal_ip = spoke.internal_ip

    public_key = (spoke.public_key != ""
      ? spoke.public_key
      : wireguard_asymmetric_key.spoke_peer[spoke.internal_ip].public_key
    )

    systemd_netdev = <<EOC
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

    systemd_network = <<EOC
        [Match]
        Name=${var.interface}

        [Network]
        Address=${spoke.internal_ip}/${var.mesh_prefix}
      %{for addr in spoke.dns}
        DNS=${addr}
      %{endfor}
    EOC

    wg_quick_conf = replace(
      data.wireguard_config_document.spoke[spoke.alias].conf,
      "/PrivateKey ?= ?/",
      # if the public key was provided, private part is unknown and we rendered public as a dummy
      spoke.public_key != "" ? "PrivateKey = # for " : "PrivateKey = "
    )
  } }
}

data "wireguard_config_document" "spoke" {
  for_each = { for s in var.spoke_peers : s.alias => s }

  addresses = [
    "${each.value.internal_ip}/${var.mesh_prefix}",
  ]

  dns = each.value.dns

  # private key is required, so if we don't know it
  # (because we didn't generate it, public part was provided)
  # then use pub key instead and strip later.
  private_key = (each.value.public_key != ""
    ? each.value.public_key
    : wireguard_asymmetric_key.spoke_peer[each.value.internal_ip].private_key
  )

  dynamic "peer" {
    for_each = local.peers
    content {
      public_key = wireguard_asymmetric_key.remote_peer[peer.key].public_key
      allowed_ips = [
        "${peer.value.internal_ip}/32",
      ]
      endpoint = (peer.value.endpoint != ""
        ? "${peer.value.endpoint}:${peer.value.port}"
        : ""
      )
    }
  }
}

resource "null_resource" "systemd_conf" {
  for_each = var.use_extant_systemd_conf ? {} : local.peers

  triggers = {
    id = each.value.id
  }

  connection {
    host        = each.value.ssh_host
    user        = each.value.ssh_user
    private_key = each.value.ssh_key
    agent       = each.value.ssh_key == ""
  }

  provisioner "remote-exec" {
    inline = [
      "set -o errexit", # https://github.com/hashicorp/terraform/issues/27554
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
      "set -o errexit", # https://github.com/hashicorp/terraform/issues/27554
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

  triggers = {
    key  = each.value.id
    peer = local.peers[each.key].id
  }

  connection {
    host        = local.peers[each.key].ssh_host
    user        = local.peers[each.key].ssh_user
    private_key = local.peers[each.key].ssh_key
    agent       = local.peers[each.key].ssh_key == ""
  }

  provisioner "remote-exec" {
    inline = [
      "set -o errexit", # https://github.com/hashicorp/terraform/issues/27554
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
      "set -o errexit", # https://github.com/hashicorp/terraform/issues/27554
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
    id           = each.value.id
    internal_ips = md5(join("", [for p in concat(values(local.peers), values(local.spokes)) : p.internal_ip]))
    keys         = md5(join("", concat([for k in null_resource.keys : k.id], [for s in local.spokes : s.public_key])))
    endpoints    = md5(join("", [for p in local.peers : p.endpoint]))
  }

  connection {
    host        = each.value.ssh_host
    user        = each.value.ssh_user
    private_key = each.value.ssh_key
    agent       = each.value.ssh_key == ""
  }

  provisioner "remote-exec" {
    inline = [
      "set -o errexit", # https://github.com/hashicorp/terraform/issues/27554
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
      "set -o errexit", # https://github.com/hashicorp/terraform/issues/27554
      "systemctl restart systemd-networkd",
    ]
  }
}
