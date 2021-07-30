Configure a full-mesh WireGuard network on a list of terraform-managed peer servers, and optionally a local peer (e.g. for management).

## Dependencies

On the remote peers:
* systemd >= v243
* systemd-networkd
* Linux >= 5.6 /or/ wireguard-dkms

If `use_extant_systemd_conf`:
* configured systemd-networkd netdev with the same interface name as provided to this module (e.g. default `wg0`)
