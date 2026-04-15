terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      version = "0.89.1"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "proxmox" {
  endpoint    = var.virtual_environment_endpoint
  api_token   = var.virtual_environment_api_token
  insecure    = var.virtual_environment_is_insecure
}