locals {
  cluster_domain = "${var.cluster_name}.${var.base_domain}"
  apps_domain    = "apps.${local.cluster_domain}"

  # Split the map once; every other file consumes these.
  bootstrap_name = one([for name, n in var.nodes : name if n.role == "bootstrap"])
  masters        = { for name, n in var.nodes : name => n if n.role == "master" && n.enabled }
  workers        = { for name, n in var.nodes : name => n if n.role == "worker" && n.enabled }

  # The bootstrap node exists only until bootstrapping finishes. Flipping
  # destroy_bootstrap drops it from the map and from the load balancer in the
  # same apply, which is the hand step the UPI documentation describes.
  # What actually gets built: everything enabled, minus the bootstrap node once
  # it has done its job.
  live_nodes = {
    for name, n in var.nodes : name => n
    if n.enabled && !(n.role == "bootstrap" && var.destroy_bootstrap)
  }

  prefix     = tonumber(split("/", var.machine_network_cidr)[1])
  node_count = { for role in ["bootstrap", "master", "worker"] : role => length([for n in var.nodes : n if n.role == role && n.enabled]) }
}
