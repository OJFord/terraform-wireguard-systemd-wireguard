locals {
  peer_idx = toset(range(length(var.peers)))
  peers    = { for idx in local.peer_idx : idx => var.peers[idx] }

  keyfile = var.key_filename
  pubfile = "${local.keyfile}.pub"

  configure_local_peer = var.local_peer.internal_ip == ""
  local_peer_conf_file = "${path.module}/local_peer.conf"
}

resource "null_resource" "systemd_conf" {
  for_each = var.use_extant_systemd_conf ? {} : local.peers

  provisioner "file" {
    content     = <<EOC
      [Match]
      Name=${var.interface}
EOC
    destination = "/etc/systemd/network/${var.interface}.network"
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
    destination = "/etc/systemd/network/${var.interface}.netdev"
  }
}

resource "null_resource" "address" {
  for_each = local.peers

  triggers = {
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
    destination = "/etc/systemd/network/${var.interface}.network.d/address.conf"
  }
}

resource "null_resource" "keys" {
  for_each = local.peers

  triggers = {
    ip = each.value.id
  }

  connection {
    host = each.value.ssh_host
    user = each.value.ssh_user
  }

  provisioner "remote-exec" {
    inline = [
      "wg genkey > '${local.keyfile}'",
      "wg pubkey < '${local.keyfile}' > '${local.pubfile}'",
    ]
  }
}

data "external" "pubkeys" {
  for_each = local.peers

  depends_on = [
    null_resource.keys,
  ]

  program = [
    "sh",
    "-c",
    "jq -n --arg pubkey \"$(ssh ${each.value.ssh_user}@${each.value.ssh_host} cat ${local.pubfile})\" '{$pubkey}'",
  ]
}

data "external" "local_peer_key" {
  count   = local.configure_local_peer ? 1 : 0
  program = ["/bin/sh", "-c", "jq -n --arg key $(wg genkey) '{$key}'"]
}

data "external" "local_peer_pubkey" {
  count   = local.configure_local_peer ? 1 : 0
  program = ["/bin/sh", "-c", "jq -r '.key' | wg pubkey | xargs -I@ echo '\"@\"' | jq '{pubkey:.}'"]
  query   = data.external.local_peer_key[0].result
}

resource "local_file" "local_peer_key" {
  count = local.configure_local_peer ? 1 : 0

  lifecycle {
    ignore_changes = [
      sensitive_content, # otherwise we get a new key on every apply
    ]
  }

  sensitive_content = data.external.local_peer_key[0].result.key
  filename          = "${path.module}/local_peer.key"

  provisioner "local-exec" {
    command = "chmod 0400 ${self.filename}"
  }
}

resource "local_file" "local_peer_pubkey" {
  count = local.configure_local_peer ? 1 : 0

  lifecycle {
    ignore_changes = [
      content, # otherwise we get a new key on every apply
    ]
  }

  content  = data.external.local_peer_pubkey[0].result.pubkey
  filename = "${path.module}/local_peer.pub"

  provisioner "local-exec" {
    command = "chmod 0400 ${self.filename}"
  }
}

resource "null_resource" "local_peer_conf" {
  count = local.configure_local_peer ? 1 : 0

  # null_resource allows us to trigger change, but not churn due to apply-time reading of keys
  triggers = {
    peers   = md5(join("", null_resource.wireguard.*.id))
    address = var.local_peer.internal_ip
    prefix  = var.mesh_prefix
    port    = var.local_peer.port
    key     = local_file.local_peer_pubkey[0].content
  }

  provisioner "local-exec" {
    command = <<EOC
      cat <<'EOF' > '${local.local_peer_conf_file}'
        [Interface]
        Address=${var.local_peer.internal_ip}/${var.mesh_prefix}
        ListenPort=${var.local_peer.port}
        PrivateKey=${local_file.local_peer_key[0].sensitive_content}

      %{for peer in local.peers}
        [Peer]
        PublicKey=${data.external.pubkeys[index(var.peers, peer)].result.pubkey}
        AllowedIPs=${peer.internal_ip}/32
      %{if peer.endpoint != ""}
        Endpoint=${peer.endpoint}:${peer.port}
      %{endif}
      %{endfor}
EOF
EOC
  }

  provisioner "local-exec" {
    command = "chmod 0400 ${local.local_peer_conf_file}"
  }
}

resource "null_resource" "peers" {
  for_each = local.peers

  triggers = {
    hostnames    = md5(join("", [for p in local.peers : p.hostname]))
    internal_ips = md5(join("", [for p in local.peers : p.internal_ip]))
    keys         = md5(join("", [for k in null_resource.keys : k.id]))
    endpoints    = md5(join("", [for p in local.peers : p.endpoint]))
  }

  connection {
    host = each.value.ssh_host
    user = each.value.ssh_user
  }

  provisioner "file" {
    content     = <<EOC
    %{for peer in local.peers}
      [WireGuardPeer]
      PublicKey=${data.external.pubkeys[index(var.peers, peer)].result.pubkey}

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
      PublicKey=${local_file.local_peer_pubkey[0].content}
      AllowedIPs=${var.local_peer.internal_ip}/32
    %{endif}
EOC
    destination = "/etc/systemd/network/${var.interface}.netdev.d/peers.conf"
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
