###### Connection to Proxmox ######
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


###### Proxmox Settings/Configuration ######
variable "node_name" {
    type = string
    description = "Target Proxmox Node"
}

variable "template_datastore" {
  type        = string
  description = "Datastore for LXC templates"
  default     = "local"
}

variable "rootfs_datastore" {
  type        = string
  description = "Datastore for container rootfs"
  default     = "local-lvm"
}

variable "network_bridge" {
  type        = string
  description = "Network bridge for containers"
  default     = "vmbr0"
}

variable "container_password" {
  type        = string
  description = "Password for test container"
  sensitive   = true
}