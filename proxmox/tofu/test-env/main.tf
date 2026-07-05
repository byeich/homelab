# Throwaway k3s test env, managed via scripts/test-env.sh (see README).
# Keep the vm resource in sync with ../main.tf until refactored into a module.

locals {
  gateway    = "10.0.0.1"
  dns_server = "10.0.0.53"

  vms = {
    k3s-test-control-1 = { vm_id = 390, memory = 3072, cores = 2, ip = "10.0.0.240/24", node = "homelab", longhorn_disk_size = 10, template_id = 9001 }
    k3s-test-worker-1  = { vm_id = 391, memory = 2048, cores = 2, ip = "10.0.0.241/24", node = "homelab", longhorn_disk_size = 10, template_id = 9001 }
  }
}

resource "proxmox_virtual_environment_vm" "k3s_test_vms" {
  for_each  = local.vms
  node_name = each.value.node
  vm_id     = each.value.vm_id
  name      = each.key

  # "testing" renders red: pvesh set /cluster/options --tag-style color-map=testing:FF0000:FFFFFF
  description = "Managed by OpenTofu - throwaway k3s test env"
  tags        = ["opentofu", "debian", "testing"]

  agent {
    enabled = true
    trim    = true
  }

  clone {
    vm_id = each.value.template_id
    full  = false
  }

  initialization {
    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = local.gateway
      }
    }

    dns {
      servers = [local.dns_server]
    }

    user_account {
      username = "debian"
      keys     = [trimspace(file(var.vm_ssh_public_key_path))]
    }
  }

  network_device {
    bridge = var.vm_network_bridge
    model  = "virtio"
  }

  disk {
    datastore_id = var.vm_rootfs_datastore
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 32
    ssd          = false
  }

  # Longhorn data disk (workers only)
  dynamic "disk" {
    for_each = strcontains(each.key, "worker") ? [1] : []
    content {
      datastore_id = var.vm_rootfs_datastore
      interface    = "scsi1"
      iothread     = true
      discard      = "on"
      size         = each.value.longhorn_disk_size
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

locals {
  control_hosts = {
    for name, vm in proxmox_virtual_environment_vm.k3s_test_vms :
    name => { ip = split("/", local.vms[name].ip)[0] }
    if strcontains(name, "control")
  }

  worker_hosts = {
    for name, vm in proxmox_virtual_environment_vm.k3s_test_vms :
    name => { ip = split("/", local.vms[name].ip)[0] }
    if strcontains(name, "worker")
  }
}

resource "local_file" "test_inventory" {
  content = templatefile("${path.module}/test-inventory.tftpl", {
    k3s_control_hosts = local.control_hosts
    k3s_worker_hosts  = local.worker_hosts
  })
  filename = "${path.module}/../../ansible/test-inventory.ini"
}
