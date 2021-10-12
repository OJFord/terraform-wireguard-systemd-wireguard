variable "mesh_prefix" {
  description = "Prefix size of the private network for peer internal IP addresses"
  type        = number
}

variable "mesh_peers" {
  description = <<EOD
    List of peers for which to configure a WireGuard mesh.

      * id: Terraform ID of the peer's server resource (on which to trigger replacements)

      * egress: Whether to use this peer for outgoing traffic; i.e. non-egress peers will send all traffic via egress peers

      * endpoint: Public address for other peers to use as its `Endpoint`; may be blank (`""`) if not applicable

      * hostname: The peer's hostname

      * internal_ip: Private IP for this peer in the WireGuard network

      * port: Port on which WireGuard is listening, e.g. `51820`

      * ssh_host: Reachable address to connect to this peer over SSH

      * ssh_user: Username to use in connecting to this peer with SSH

      * ssh_key: Optional private key to use instead of an agent
EOD
  type = list(object({
    id          = string
    egress      = bool
    endpoint    = string
    hostname    = string
    internal_ip = string
    port        = number
    ssh_host    = string
    ssh_user    = string
    ssh_key     = string
  }))
}

variable "interface" {
  description = "Name of the network interface to create, or that already exists if `use_extant_systemd_conf`"
  type        = string
  default     = "wg0"
}

variable "key_filename" {
  description = "Location of WireGuard private key, if `use_extant_systemd_conf`, set to where that config expects it"
  type        = string
  default     = "/etc/wireguard/key"
}

variable "spoke_peers" {
  description = "Extra non-meshed peers to allow. Key will be generated if not provided."
  type = list(object({
    alias       = string
    dns         = list(string)
    egress      = bool
    internal_ip = string
    port        = number
    public_key  = string
  }))

  default = []
}

variable "use_extant_systemd_conf" {
  description = "Whether to use existing systemd-networkd netdev & network, or create them"
  type        = bool
  default     = false
}

variable "systemd_dir" {
  description = "Location of the systemd configuration; override may be needed if `use_extant_systemd_conf` true"
  type        = string
  default     = "/etc/systemd/network"
}
