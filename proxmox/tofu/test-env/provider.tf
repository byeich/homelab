terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.111.1"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
  # local state on purpose, must never touch the B2 prod state
}

provider "proxmox" {
  endpoint  = var.virtual_environment_endpoint
  api_token = var.virtual_environment_api_token
  insecure  = var.virtual_environment_is_insecure
}
