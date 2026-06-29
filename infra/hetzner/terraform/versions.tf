terraform {
  required_version = ">= 1.10.0"

  required_providers {
    # The hcloud-talos module configures hcloud/helm/kubectl providers internally; the root only needs
    # the providers it references directly (hcloud for the token, talos to type the config outputs).
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.65.0"
    }

    talos = {
      source  = "siderolabs/talos"
      version = ">= 0.11.0"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}
