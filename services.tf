# DNS and load balancing for the cluster, on one small VM.
#
# A user-provisioned install assumes both already exist. On a hypervisor they
# usually do not, and putting them on the host means editing the host's
# resolver and firewall. A VM keeps the whole cluster, including the parts the
# installer refuses to create, inside `terraform destroy`.
#
# Note on the bootstrap node: the documented UPI procedure is to remove it from
# the load balancer by hand once bootstrapping finishes. This config leaves it
# listed. Once the machine is gone the health check fails, haproxy marks the
# backend DOWN and stops sending to it, which reaches the same end state
# without a second config render and a reload at the most fragile moment of
# the install.

locals {
  services_mac = join(":", [
    "52", "54", "00",
    substr(md5("${var.cluster_name}-services"), 0, 2),
    substr(md5("${var.cluster_name}-services"), 2, 2),
    substr(md5("${var.cluster_name}-services"), 4, 2),
  ])

  services_name = "${var.cluster_name}-services"

  # Control plane answers the API and the machine config server; the bootstrap
  # node answers both too, until it is gone.
  api_members = { for name, n in var.nodes : name => n.ip if contains(["bootstrap", "master"], n.role) }

  # The router runs on the workers, or on the control plane when there are no
  # workers and it has been made schedulable.
  ingress_members = length(local.workers) > 0 ? { for name, n in local.workers : name => n.ip } : { for name, n in local.masters : name => n.ip }

  backends = {
    api           = join("\n", [for name, ip in local.api_members : "    server ${name} ${ip}:6443 check inter 1s"])
    mcs           = join("\n", [for name, ip in local.api_members : "    server ${name} ${ip}:22623 check inter 1s"])
    ingress_http  = join("\n", [for name, ip in local.ingress_members : "    server ${name} ${ip}:80 check inter 1s"])
    ingress_https = join("\n", [for name, ip in local.ingress_members : "    server ${name} ${ip}:443 check inter 1s"])
  }

  haproxy_cfg = templatefile("${path.module}/templates/haproxy.cfg.tftpl", {
    api_backends           = local.backends.api
    mcs_backends           = local.backends.mcs
    ingress_http_backends  = local.backends.ingress_http
    ingress_https_backends = local.backends.ingress_https
  })

  dnsmasq_conf = !var.manage_cluster_dns ? "" : templatefile("${path.module}/templates/dnsmasq.conf.tftpl", {
    cluster_domain   = local.cluster_domain
    listen_address   = var.services_ip
    lb_address       = var.services_ip
    forward_to       = var.cluster_dns_forward_to
    upstream_servers = join("\n", [for s in var.upstream_dns : "server=${s}"])
    node_records     = join("\n", [for name, n in var.nodes : "host-record=${name}.${local.cluster_domain},${n.ip}"])
  })

  services_user_data = templatefile("${path.module}/templates/services-user-data.yaml.tftpl", {
    manage_dns     = var.manage_cluster_dns
    hostname       = local.services_name
    cluster_name   = var.cluster_name
    cluster_domain = local.cluster_domain
    username       = var.services_user
    timezone       = "UTC"
    # Every one of these is indented into a `content: |` block. A template
    # directive or an unindented line at column 0 inside a block scalar ends
    # the block, and the rest silently never reaches the file.
    # Indented inside the template, at the point of use: indent() leaves the
    # FIRST line alone, so indenting here puts line one at column 0 and ends
    # the block scalar it was meant to sit inside.
    ssh_keys     = join("\n", [for k in var.ssh_authorized_keys : "- ${k}"])
    dnsmasq_conf = trimspace(local.dnsmasq_conf)
    haproxy_cfg  = trimspace(local.haproxy_cfg)
  })
}

resource "libvirt_cloudinit_disk" "services" {
  count = var.manage_services_vm ? 1 : 0

  name      = "${local.services_name}-cloudinit.iso"
  user_data = local.services_user_data

  meta_data = yamlencode({
    instance-id    = local.services_name
    local-hostname = local.services_name
  })

  # The services VM resolves through its upstream, not through its own dnsmasq:
  # pointing it at itself before dnsmasq starts leaves cloud-init unable to
  # reach the package mirrors.
  network_config = templatefile("${path.module}/templates/services-network-config.yaml.tftpl", {
    mac            = local.services_mac
    ip             = var.services_ip
    prefix         = local.prefix
    gateway        = var.gateway_ip
    upstream_dns   = join(", ", var.upstream_dns)
    cluster_domain = local.cluster_domain
  })
}

resource "libvirt_volume" "services_init" {
  count = var.manage_services_vm ? 1 : 0

  name = "${local.services_name}-cloudinit.iso"
  pool = var.pool

  # "iso", not "raw": libvirt sniffs the uploaded image and reports iso back,
  # and a mismatch fails the apply with "produced an unexpected new value".
  target = {
    format = { type = "iso" }
  }

  create = {
    content = { url = libvirt_cloudinit_disk.services[0].path }
  }
}

resource "libvirt_volume" "services_root" {
  count = var.manage_services_vm ? 1 : 0

  name          = "${local.services_name}.qcow2"
  pool          = var.pool
  capacity      = var.services_disk_size
  capacity_unit = "GiB"

  target = {
    format = { type = "qcow2" }
  }

  backing_store = {
    path   = libvirt_volume.services_base[0].path
    format = { type = "qcow2" }
  }
}

resource "libvirt_domain" "services" {
  count = var.manage_services_vm ? 1 : 0

  name        = local.services_name
  type        = "kvm"
  memory      = var.services_memory
  memory_unit = "MiB"
  vcpu        = var.services_vcpu
  autostart   = var.autostart
  running     = true

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = var.machine_type
    boot_devices = [{ dev = "hd" }]
  }

  cpu = {
    mode = var.cpu_mode
  }

  destroy = var.shutdown_timeout > 0 ? {
    shutdown = { timeout = var.shutdown_timeout }
  } : null

  devices = {
    disks = [
      {
        device = "disk"
        driver = { name = "qemu", type = "qcow2" }
        source = { file = { file = libvirt_volume.services_root[0].path } }
        target = { dev = "vda", bus = "virtio" }
      },
      {
        device = "cdrom"
        driver = { name = "qemu", type = "raw" }
        source = { file = { file = libvirt_volume.services_init[0].path } }
        target = { dev = "sda", bus = "sata" }
      },
    ]

    interfaces = [{
      mac    = { address = local.services_mac }
      model  = { type = "virtio" }
      source = { network = { network = local.network } }
    }]

    serials  = [{ target = { port = 0 } }]
    consoles = [{ target = { type = "serial", port = 0 } }]

    channels = var.qemu_agent ? [{
      target = { virt_io = { name = "org.qemu.guest_agent.0" } }
      source = { mode = "bind" }
    }] : []

    graphics = var.graphics == "none" ? [] : [
      var.graphics == "spice"
      ? { spice = { auto_port = true, listen = "127.0.0.1" } }
      : { vnc = { auto_port = true, listen = "127.0.0.1" } }
    ]
  }
}
