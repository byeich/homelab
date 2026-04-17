locals {
    defaults = {
        node        = var.node_name
        bridge      = var.network_bridge
        rootds      = var.rootfs_datastore
        tmpl_id     = proxmox_virtual_environment_download_file.debian_lxc.id
        vm_node     = var.vm_node_name
        vm_bridge   = var.vm_network_bridge
        vm_rootds   = var.rootfs_datastore
    }

    containers = {
        pihole   = { vm_id = 303, memory = 512, cores = 1 , ip = "10.0.0.53/24"}
    }

    # K3s VMs    
    vms = {
        # Control Plane Nodes
        k3s-control-1 = { vm_id = 310, memory = 4096, cores = 2, ip = "10.0.0.60/24" }
        k3s-control-2 = { vm_id = 311, memory = 4096, cores = 2, ip = "10.0.0.61/24" }
        k3s-control-3 = { vm_id = 312, memory = 4096, cores = 2, ip = "10.0.0.62/24" }
        
        # Worker Nodes
        k3s-worker-1  = { vm_id = 320, memory = 4096, cores = 2, ip = "10.0.0.70/24" }
        k3s-worker-2  = { vm_id = 321, memory = 4096, cores = 2, ip = "10.0.0.71/24" }
        k3s-worker-3  = { vm_id = 322, memory = 4096, cores = 2, ip = "10.0.0.72/24" }
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

  unprivileged = true
  started      = true
}

###### Create K3s VMs ######
resource "proxmox_virtual_environment_vm" "k3s_vms" {
  for_each  = local.vms
  node_name = local.defaults.vm_node
  vm_id     = each.value.vm_id
  name      = each.key

  description = "Managed by OpenTofu - K3s ${each.key}"
  tags        = ["opentofu", "debian", "k3s"]

  agent {
    enabled = true
    trim    = true
  }

  clone {
    vm_id = 9000  #id of debian template in proxmox
    full  = false
  }

  initialization {
    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = "10.0.0.1"
      }
    }
    
    dns {
      servers = ["10.0.0.53"]  # pihole container ip
    }

    user_account {
      username = "debian"
      keys     = [trimspace(file("~/.ssh/k3s_cluster.pub"))]
    }
  }

  network_device {
    bridge = local.defaults.vm_bridge
    model  = "virtio"
  }

  disk {
    datastore_id = local.defaults.vm_rootds
    interface    = "scsi0"
    iothread     = true
    discard      = "on"
    size         = 32
    ssd          = true
  }

  # Longhorn data disk (workers only)
  dynamic "disk" {
    for_each = startswith(each.key, "k3s-worker") ? [1] : []
    content {
      datastore_id = local.defaults.vm_rootds
      interface    = "scsi1"
      iothread     = true
      discard      = "on"
      size         = 50
      ssd          = true
    }
  }

  memory {
    dedicated = each.value.memory
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  started = true
}

###### Ansible Inventory ######
locals {
  k3s_control_hosts = {
    for name, vm in proxmox_virtual_environment_vm.k3s_vms :
    name => { ip = split("/", local.vms[name].ip)[0] }
    if startswith(name, "k3s-control")
  }

  k3s_worker_hosts = {
    for name, vm in proxmox_virtual_environment_vm.k3s_vms :
    name => { ip = split("/", local.vms[name].ip)[0] }
    if startswith(name, "k3s-worker")
  }
}

resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/../ansible/inventory.tftpl", {
    pihole_host       = split("/", local.containers["pihole"].ip)[0]
    k3s_control_hosts = local.k3s_control_hosts
    k3s_worker_hosts  = local.k3s_worker_hosts
  })
  filename = "${path.module}/../ansible/inventory.ini"
}