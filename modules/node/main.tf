locals {
  # A deterministic MAC in the QEMU 52:54:00 range. The NetworkManager keyfile
  # matches the NIC by address, because the name RHCOS gives a virtio NIC is
  # not something this module can promise across machine types.
  mac = join(":", [
    "52", "54", "00",
    substr(md5(var.name), 0, 2),
    substr(md5(var.name), 2, 2),
    substr(md5(var.name), 4, 2),
  ])

  fqdn = "${var.name}.${var.cluster_domain}"

  # UPI on libvirt has no DHCP, so the address has to arrive with the machine.
  # A keyfile is the only mechanism RHCOS 4.x offers: ifcfg files are gone, and
  # `ip=` kernel arguments would have to be baked into every boot entry.
  nmconnection = <<-EOT
    [connection]
    id=primary
    type=ethernet
    autoconnect=true
    autoconnect-priority=100

    [ethernet]
    mac-address=${local.mac}

    [ipv4]
    method=manual
    addresses=${var.ip}/${var.prefix}
    gateway=${var.gateway}
    dns=${var.nameserver};
    dns-search=${var.cluster_domain};
    may-fail=false

    [ipv6]
    method=disabled
  EOT

  node_files = [
    {
      path      = "/etc/hostname"
      mode      = 420 # 0644
      overwrite = true
      contents  = { source = "data:text/plain;base64,${base64encode("${local.fqdn}\n")}" }
    },
    {
      path      = "/etc/NetworkManager/system-connections/primary.nmconnection"
      mode      = 384 # 0600, NetworkManager refuses to read a keyfile that is any wider
      overwrite = true
      contents  = { source = "data:text/plain;base64,${base64encode(local.nmconnection)}" }
    },
  ]

  base = jsondecode(var.ignition_base)

  # Merged, not replaced. master.ign and worker.ign are pointer configs with no
  # files of their own, but bootstrap.ign carries about three hundred, and
  # overwriting that list produces a node that boots into nothing.
  ignition = jsonencode(merge(local.base, {
    storage = merge(
      try(local.base.storage, {}),
      { files = concat(try(local.base.storage.files, []), local.node_files) },
    )
  }))
}

# Copy-on-write overlay, not a copy: one bootimage serves the whole cluster.
resource "libvirt_volume" "root" {
  name          = "${var.name}.qcow2"
  pool          = var.pool
  capacity      = var.disk_size
  capacity_unit = "GiB"

  target = {
    format = { type = "qcow2" }
  }

  backing_store = {
    path   = var.base_volume_path
    format = { type = "qcow2" }
  }
}

# Written to /tmp/terraform-provider-libvirt-ignition/ on the machine running
# Terraform, and read from there by libvirtd when the domain starts. That is
# why this stack has to run on the hypervisor, and why a host reboot between
# apply and first boot needs a re-apply.
resource "libvirt_ignition" "node" {
  name    = "${var.name}.ign"
  content = local.ignition
}

resource "libvirt_domain" "node" {
  name        = var.name
  type        = "kvm"
  memory      = var.memory
  memory_unit = "MiB"
  vcpu        = var.vcpu
  autostart   = var.autostart
  running     = true

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = var.machine_type
    firmware     = var.firmware == "efi" ? "efi" : null
    boot_devices = [{ dev = "hd" }]
  }

  cpu = {
    mode = var.cpu_mode
  }

  # How Ignition reaches a CoreOS guest on libvirt: the firmware exposes the
  # file at opt/com.coreos/config and Ignition reads it in the initramfs on
  # first boot. `value` is required by the schema but is dropped from the XML
  # when `file` is set.
  sys_info = [{
    fw_cfg = {
      entry = [{
        name  = "opt/com.coreos/config"
        value = ""
        file  = libvirt_ignition.node.path
      }]
    }
  }]

  # ACPI shutdown first, force only on timeout.
  destroy = var.shutdown_timeout > 0 ? {
    shutdown = { timeout = var.shutdown_timeout }
  } : null

  devices = {
    disks = [{
      device = "disk"
      driver = { name = "qemu", type = "qcow2" }
      source = { file = { file = libvirt_volume.root.path } }
      target = { dev = "vda", bus = "virtio" }
    }]

    interfaces = [{
      mac    = { address = local.mac }
      model  = { type = "virtio" }
      source = { network = { network = var.network } }
    }]

    # Serial console, so `virsh console` shows the Ignition run and the
    # bootstrap progress with no display attached.
    serials  = [{ target = { port = 0 } }]
    consoles = [{ target = { type = "serial", port = 0 } }]

    # The channel target is a union, not a type string: which nested object you
    # set is what picks the kind.
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
