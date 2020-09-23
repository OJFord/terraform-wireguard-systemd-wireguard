terraform {
  required_providers {
    external = {
      source = "hashicorp/external"
    }
    local = {
      source = "hashicorp/local"
    }
    null = {
      source = "hashicorp/null"
    }
    wireguard = {
      source = "OJFord/wireguard"
    }
  }
  required_version = ">= 0.13"
}
