locals {
    defaults = {
        node     = var.node_name
        bridge   = var.network_bridge
        rootds   = var.rootfs_datastore
        tmpl_id  = proxmox_virtual_environment_download_file.debian_lxc.id
    }

    containers = {
        # jellyfin = { vm_id = 301, memory = 1024, cores = 1, ip = "10.0.0.51/24" }
        # vault    = { vm_id = 302, memory = 1024, cores = 1, ip = "10.0.0.52/24" }
        pihole   = { vm_id = 303, memory = 512, cores = 1 , ip = "10.0.0.53/24"}
        # pihole   = { vm_id = 304, memory = 512, cores = 1 , ip = "10.0.0.54/24"}
    }
}


###### Download LXC Template ######
resource "proxmox_virtual_environment_download_file" "debian_lxc" {
    node_name = var.node_name
    content_type = "vztmpl"
    datastore_id = var.template_datastore

    url = "http://download.proxmox.com/images/system/debian-12-standard_12.2-1_amd64.tar.zst"
}


###### Create LXC containers ######
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
      ipv4 { 
        address = each.value.ip
        gateway = "10.0.0.1" 
      }
    }

    user_account { keys = [trimspace(file("~/.ssh/id_ed25519.pub"))] }
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

  unprivileged = true  #default false
  started      = true  #default
}
