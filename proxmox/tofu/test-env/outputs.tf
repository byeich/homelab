output "control_ip" {
  description = "Test control node IP, used by scripts/test-env.sh verify"
  value       = split("/", local.vms["k3s-test-control-1"].ip)[0]
}

output "node_count" {
  description = "Expected number of k3s nodes in the test cluster"
  value       = length(local.vms)
}
