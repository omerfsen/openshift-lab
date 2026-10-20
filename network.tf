# A dedicated network per cluster, NAT to the outside - when this stack owns
# the network at all. Joining an existing one is often better: a network your
# VPN or your office already routes needs no new route, no firewall change and
# no bridge, and the cluster is simply a tenant on it.
#
# DHCP is deliberately absent. Every node is addressed statically from its
# Ignition config, so there is no lease to expire mid-install and no dependency
# on a DHCP server surviving a bootstrap reboot. libvirt's own DNS is left on
# only for the host entries below; everything the cluster needs - the wildcard
# *.apps record in particular, which libvirt's <dns> cannot express - is
# answered by dnsmasq on the services VM.
resource "libvirt_network" "cluster" {
  count = var.create_network ? 1 : 0

  name      = var.network_name
  autostart = true

  bridge = {
    name = var.network_bridge
  }

  forward = {
    mode = "nat"
  }

  ips = [{
    family  = "ipv4"
    address = var.gateway_ip
    prefix  = tonumber(split("/", var.machine_network_cidr)[1])
  }]

  dns = {
    enable = "yes"

    # Resolvable from the hypervisor without touching the host's resolver, so
    # `oc` and a browser on this machine can reach the cluster. The wildcard
    # still only exists on the services VM.
    host = concat(
      [{
        ip        = var.services_ip
        hostnames = [{ hostname = "api.${local.cluster_domain}" }]
        }, {
        ip        = var.services_ip
        hostnames = [{ hostname = "api-int.${local.cluster_domain}" }]
      }],
      [
        for name, n in var.nodes : {
          ip        = n.ip
          hostnames = [{ hostname = "${name}.${local.cluster_domain}" }]
        }
      ],
    )
  }
}

locals {
  # The one place the rest of the stack asks "which network?", so joining and
  # creating look identical everywhere else.
  network = var.create_network ? libvirt_network.cluster[0].name : var.network_name
}
