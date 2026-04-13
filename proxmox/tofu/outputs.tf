output "k3s_vm_ids" {
  description = "Proxmox VM IDs for each k3s node"
  value = {
    for name, vm in proxmox_virtual_environment_vm.k3s_vms :
    name => vm.vm_id
  }
}

output "k3s_ipv4_addresses" {
  description = "Actual IPs reported by qemu-guest-agent (confirms cloud-init applied network config)"
  value = {
    for name, vm in proxmox_virtual_environment_vm.k3s_vms :
    name => vm.ipv4_addresses
  }
}

output "ansible_inventory_path" {
  description = "Path to the generated Ansible inventory file"
  value       = local_file.ansible_inventory.filename
}
