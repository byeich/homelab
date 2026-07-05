# Same names as ../variables.tf so ../variables.auto.tfvars can be reused

variable "virtual_environment_endpoint" {
  type        = string
  description = "Proxmox API endpoint (https://ip-of-host:port/)"
}

variable "virtual_environment_api_token" {
  type        = string
  description = "Proxmox API token (user@realm!token=secret)"
  sensitive   = true
}

variable "virtual_environment_is_insecure" {
  type        = bool
  description = "Allow self-signed certs"
  default     = true
}

variable "vm_rootfs_datastore" {
  type        = string
  description = "Datastore for vm rootfs"
  default     = "local-lvm"
}

variable "vm_network_bridge" {
  type        = string
  description = "Network bridge for vms"
  default     = "vmbr0"
}

variable "vm_ssh_public_key_path" {
  type        = string
  description = "Path to SSH public key for k3s VMs"
  default     = "~/.ssh/k3s_cluster.pub"
}
