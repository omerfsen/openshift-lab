output "uuid" {
  description = "libvirt domain UUID."
  value       = libvirt_domain.node.uuid
}

output "mac" {
  description = "MAC of the primary interface, which the NetworkManager keyfile matches on."
  value       = local.mac
}

output "ip" {
  description = "Static address configured on the node."
  value       = var.ip
}

output "fqdn" {
  description = "Hostname written to /etc/hostname."
  value       = local.fqdn
}

output "root_volume_path" {
  description = "Path of the copy-on-write root disk."
  value       = libvirt_volume.root.path
}
