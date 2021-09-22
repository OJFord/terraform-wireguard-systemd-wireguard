# systemd-wireguard [terraform module](https://registry.terraform.io/modules/OJFord/systemd-wireguard/wireguard/latest)

This is a systemd-provisioning module for the [WireGuard terraform provider](https://registry.terraform.io/providers/OJFord/wireguard/latest). It configures a 'mesh & spoke' WireGuard network from a (non-empty) list of terraform-managed peer servers to be in a fully-connected mesh, and optionally 'spoke' peers that connect to the meshed hub, but not to each other directly; useful for example for administrative access to servers, or for remote access to an internal network.

## Dependencies

On the remote peers:
* systemd >= v243
* systemd-networkd
* Linux >= 5.6 /or/ wireguard-dkms

If [`use_extant_systemd_conf`](https://registry.terraform.io/modules/OJFord/systemd-wireguard/wireguard/latest?tab=inputs#optional-inputs):
* configured systemd-networkd netdev with the same interface name as provided to this module (e.g. default `wg0`)

There is *no* requirement for wireguard (or wireguard-tools) to be installed on the machine executing terraform.
