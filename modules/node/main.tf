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

  use_config_drive = var.ignition_delivery == "config-drive"
  drive_dir        = "${var.config_dir}/${var.name}"
  iso_path         = "${var.config_dir}/${var.name}-config.iso"

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

# ─────────────────────── delivery 1: config drive ────────────────────────
# An ISO labelled config-2 with the config at openstack/latest/user_data, which
# is where Ignition looks when the image boots with
# ignition.platform.id=openstack. It mounts the drive, reads the config and
# unmounts it - visible in the console as `fetched user config from "openstack"`.
resource "local_sensitive_file" "user_data" {
  count = local.use_config_drive ? 1 : 0

  filename        = "${local.drive_dir}/openstack/latest/user_data"
  content         = local.ignition
  file_permission = "0600"
}

resource "terraform_data" "config_drive" {
  count = local.use_config_drive ? 1 : 0

  triggers_replace = [local_sensitive_file.user_data[0].content_sha256]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-euo", "pipefail", "-c"]
    command     = <<-EOT
      command -v genisoimage >/dev/null || { echo "genisoimage is required for the config-drive delivery"; exit 1; }
      # -r for Rock Ridge: without it the ISO only carries 8.3 names and the
      # guest looks for openstack/latest/user_data, not OPENSTAC/LATEST/USER_DAT.
      genisoimage -quiet -o '${local.iso_path}' -V config-2 -r -J '${local.drive_dir}'
      test -s '${local.iso_path}'
    EOT
  }
}

resource "libvirt_volume" "config_drive" {
  count = local.use_config_drive ? 1 : 0

  name = "${var.name}-config.iso"
  pool = var.pool

  target = {
    format = { type = "iso" }
  }

  create = {
    content = { url = "file://${local.iso_path}" }
  }

  depends_on = [terraform_data.config_drive]
}

# ─────────────────────────── delivery 2: fw_cfg ──────────────────────────
# Written to /tmp/terraform-provider-libvirt-ignition/ on the machine running
# Terraform, and read from there by libvirtd when the domain starts. Whether
# the GUEST ever sees it is a property of the host's QEMU, not of this config:
# on QEMU 6.2 (Ubuntu 22.04) /sys/firmware/qemu_fw_cfg is empty in every guest
# and Ignition boots with no config at all.
resource "libvirt_ignition" "node" {
  count = local.use_config_drive ? 0 : 1

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

  # Only the fw_cfg delivery puts anything here: the firmware exposes the file
  # at opt/com.coreos/config and Ignition reads it in the initramfs on first
  # boot. `value` is required by the schema but is dropped from the XML when
  # `file` is set. The config-drive delivery attaches a cdrom instead, below.
  sys_info = local.use_config_drive ? [] : [{
    fw_cfg = {
      entry = [{
        name  = "opt/com.coreos/config"
        value = ""
        file  = libvirt_ignition.node[0].path
      }]
    }
  }]

  # ACPI shutdown first, force only on timeout.
  destroy = var.shutdown_timeout > 0 ? {
    shutdown = { timeout = var.shutdown_timeout }
  } : null

  devices = {
    disks = concat(
      [{
        device = "disk"
        driver = { name = "qemu", type = "qcow2" }
        source = { file = { file = libvirt_volume.root.path } }
        target = { dev = "vda", bus = "virtio" }
      }],
      local.use_config_drive ? [{
        device = "cdrom"
        driver = { name = "qemu", type = "raw" }
        source = { file = { file = libvirt_volume.config_drive[0].path } }
        target = { dev = "sda", bus = "sata" }
      }] : [],
    )

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
