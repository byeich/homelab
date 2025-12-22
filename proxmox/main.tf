locals {
    defaults = {
        node     = var.node_name
        bridge   = var.network_bridge
        rootds   = var.rootfs_datastore
        tmpl_id  = proxmox_virtual_environment_download_file.debian_lxc.id
    }

    containers = {
        jellyfin = { vm_id = 301, memory = 1024, cores = 1 }
        vault    = { vm_id = 302, memory = 1024, cores = 1 }
    }
}


###### Download LXC Template ######
resource "proxmox_virtual_environment_download_file" "debian_lxc" {
    node_name = var.node_name
    content_type = "vztmpl"
    datastore_id = var.template_datastore

    url = "http://download.proxmox.com/images/system/debian-12-standard_12.2-1_amd64.tar.zst"
}


###### Create Test LXC container ######
resource "proxmox_virtual_environment_container" "svc" {
  for_each  = local.containers
  node_name = local.defaults.node
  vm_id     = each.value.vm_id

  operating_system {
    template_file_id = local.defaults.tmpl_id
    type             = "debian"
  }

  initialization {
    hostname = each.key

    ip_config {
      ipv4 { address = "dhcp" }
    }

    user_account { password = var.container_password }
  }

  network_interface {
    name   = "eth0"
    bridge = local.defaults.bridge
  }

  disk {
    datastore_id = local.defaults.rootds
    size         = "16"
  }

  memory { dedicated = each.value.memory }
  cpu { cores = each.value.cores }

  unprivileged = false #default
  started      = true  #default
}

output "debian_container_password" {
    value = var.container_password
    sensitive = true
}