# One module call per machine. Which Ignition config a node gets is decided by
# its role and nothing else, which is the whole of the UPI contract: the
# installer produces three configs, and you are responsible for putting the
# right one on the right machine.
module "node" {
  source   = "./modules/node"
  for_each = local.live_nodes

  name           = each.key
  role           = each.value.role
  cluster_domain = local.cluster_domain
  pool           = var.pool

  base_volume_path = libvirt_volume.rhcos.path
  network          = local.network
  ignition_base    = data.local_file.ignition[each.value.role].content

  ip         = each.value.ip
  prefix     = local.prefix
  gateway    = var.gateway_ip
  nameserver = var.node_nameserver

  memory    = coalesce(each.value.memory, var.role_defaults[each.value.role].memory)
  vcpu      = coalesce(each.value.vcpu, var.role_defaults[each.value.role].vcpu)
  disk_size = coalesce(each.value.disk_size, var.role_defaults[each.value.role].disk_size)

  cpu_mode         = var.cpu_mode
  machine_type     = var.machine_type
  firmware         = var.firmware
  graphics         = var.graphics
  qemu_agent       = var.qemu_agent
  shutdown_timeout = var.shutdown_timeout
  autostart        = var.autostart

  # A control plane node whose pointer config cannot resolve api-int:22623
  # retries, loudly, for the whole install. Bringing DNS and the load balancer
  # up first turns that into a non-event.
  depends_on = [libvirt_domain.services]
}
