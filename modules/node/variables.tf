variable "name" {
  description = "Node name. Becomes the domain name and the first label of the hostname."
  type        = string
}

variable "role" {
  description = "bootstrap, master or worker. Picks which Ignition config is merged in."
  type        = string
}

variable "cluster_domain" {
  description = "<cluster_name>.<base_domain>, used to build the fully qualified hostname."
  type        = string
}

variable "pool" {
  description = "Storage pool for this node's disks."
  type        = string
}

variable "base_volume_path" {
  description = "Path of the shared RHCOS bootimage this node's root disk is an overlay on."
  type        = string
}

variable "network" {
  description = "libvirt network to attach to."
  type        = string
}

variable "ignition_base" {
  description = "The installer's Ignition config for this node's role, as JSON. Merged with the per-node files below."
  type        = string
  sensitive   = true
}

variable "mac" {
  description = "MAC for the primary NIC. Empty string derives one deterministically from the node name. Set it when something outside this stack already knows the address - a DHCP reservation, a switch ACL, a bare-metal BMC inventory."
  type        = string
}

variable "ip" {
  description = "Static address, without a prefix."
  type        = string
}

variable "prefix" {
  description = "Prefix length of the machine network."
  type        = number
}

variable "gateway" {
  description = "Default route."
  type        = string
}

variable "nameserver" {
  description = "Resolver the node uses. Must answer for the cluster domain, so normally the services VM."
  type        = string
}

variable "memory" {
  description = "Memory in MiB."
  type        = number
}

variable "vcpu" {
  description = "Virtual CPUs."
  type        = number
}

variable "disk_size" {
  description = "Root disk in GiB."
  type        = number
}

variable "cpu_mode" {
  description = "libvirt CPU mode."
  type        = string
}

variable "machine_type" {
  description = "QEMU machine type."
  type        = string
}

variable "firmware" {
  description = "\"bios\" or \"efi\"."
  type        = string
}

variable "graphics" {
  description = "\"vnc\", \"spice\" or \"none\"."
  type        = string
}

variable "qemu_agent" {
  description = "Attach the guest agent channel."
  type        = bool
}

variable "shutdown_timeout" {
  description = "Seconds to wait for an ACPI shutdown before forcing it."
  type        = number
}

variable "autostart" {
  description = "Start with the hypervisor."
  type        = bool
}

variable "ignition_delivery" {
  description = <<-EOT
    How the Ignition config reaches the guest.

    "config-drive": an ISO labelled config-2 holding
    openstack/latest/user_data, attached as a cdrom. Needs the **openstack**
    bootimage, which boots with ignition.platform.id=openstack.

    "fw_cfg": the config is passed through QEMU's firmware config interface
    as opt/com.coreos/config. Needs the **qemu** bootimage. Fewer moving parts,
    but the guest only sees it if the host's QEMU actually exposes fw_cfg -
    QEMU 6.2 on Ubuntu 22.04 does not, and Ignition then reports
    "QEMU firmware config was not found" and boots with no config at all.
  EOT
  type        = string

  validation {
    condition     = contains(["config-drive", "fw_cfg"], var.ignition_delivery)
    error_message = "ignition_delivery is \"config-drive\" or \"fw_cfg\"."
  }
}

variable "config_dir" {
  description = "Directory on the hypervisor where per-node config drives are staged. Only used by the config-drive delivery."
  type        = string
}
