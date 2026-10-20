# No variable carries a default. A value you forgot fails at plan time instead
# of quietly taking one buried in the code; terraform.tfvars is the only file
# you normally edit. The Azure stack this replaces had the same rule.

# ─────────────────────────────── hypervisor ───────────────────────────────

variable "libvirt_uri" {
  description = "libvirt connection URI. Must be local: the provider writes Ignition files onto the machine Terraform runs on."
  type        = string
}

variable "pool" {
  description = "Storage pool for every volume this stack creates."
  type        = string
}

# ──────────────────────────────── cluster ─────────────────────────────────

variable "cluster_name" {
  description = "Cluster name. Node hostnames and every DNS record derive from it."
  type        = string
}

variable "base_domain" {
  description = "DNS base domain. The cluster lives at <cluster_name>.<base_domain>."
  type        = string
}

variable "ocp_version" {
  description = "OpenShift release to install, e.g. \"4.22.18\". Pins openshift-install and oc."
  type        = string
}

variable "pull_secret" {
  description = "Red Hat pull secret JSON, from https://console.redhat.com/openshift/install/pull-secret."
  type        = string
  sensitive   = true
}

variable "ssh_authorized_keys" {
  description = "Public keys for the RHCOS `core` user. Installer debugging needs at least one."
  type        = list(string)
}

variable "cluster_network_cidr" {
  description = "Pod network CIDR."
  type        = string
}

variable "cluster_network_host_prefix" {
  description = "Per-node pod subnet prefix carved out of cluster_network_cidr."
  type        = number
}

variable "service_network_cidr" {
  description = "Service network CIDR."
  type        = string
}

variable "network_type" {
  description = "Cluster network plugin, e.g. \"OVNKubernetes\"."
  type        = string
}

variable "fips" {
  description = "Install in FIPS mode. Needs a FIPS-capable host and cannot be changed after install."
  type        = bool
}

# ───────────────────────────── machine network ────────────────────────────

variable "machine_network_cidr" {
  description = "Subnet the nodes sit on. Created as a dedicated libvirt network."
  type        = string
}

variable "create_network" {
  description = <<-EOT
    Create a dedicated libvirt network for this cluster. False joins one that
    already exists, which is usually right when that network is already routed
    to wherever you work from - nothing new to route, firewall or tear down.
    A joined network is never destroyed by this stack.
  EOT
  type        = bool
}

variable "network_name" {
  description = "The libvirt network: created when create_network is true, otherwise one that already exists."
  type        = string
}

variable "network_bridge" {
  description = "Bridge device for a created network; ignored when joining one. Must be unique on the host and <= 15 characters."
  type        = string
}

variable "gateway_ip" {
  description = "Address libvirt gives the bridge; the nodes' default route and DNS server."
  type        = string
}

variable "services_ip" {
  description = "Address of the services VM that answers DNS and load-balances the API and ingress."
  type        = string
}

variable "manage_cluster_dns" {
  description = <<-EOT
    Run dnsmasq on the services VM to answer for the cluster domain. Set false
    when the zone lives somewhere else - a public zone at your DNS provider, or
    a BIND you already run - and the services VM is then a load balancer and
    nothing more.
  EOT
  type        = bool
}

variable "cluster_dns_forward_to" {
  description = "Only read when manage_cluster_dns is true. Empty string makes the services VM authoritative for the cluster domain; \"<ip>#<port>\" makes it forward that domain there instead."
  type        = string
}

variable "dns_ttl" {
  description = "TTL on the generated zone records. Keep it short while the cluster is being built; a stale cached answer for api is a confusing way to lose an afternoon."
  type        = number
}

variable "node_nameserver" {
  description = <<-EOT
    Resolver the nodes are given, in their Ignition NetworkManager keyfile. It
    must resolve api-int.<cluster>.<base_domain> before the control plane
    exists, so: the services VM when it serves DNS, the libvirt network's own
    gateway when the zone is public, or any resolver that can see the records.
  EOT
  type        = string
}

variable "upstream_dns" {
  description = "Resolvers the services VM forwards everything outside the cluster domain to."
  type        = list(string)
}

# ───────────────────────────────── images ─────────────────────────────────

variable "rhcos_image_url" {
  description = "RHCOS qemu qcow2 for the bootimage. The mirror serves it gzipped; it is decompressed before upload."
  type        = string
}

variable "rhcos_image_sha256" {
  description = "SHA-256 of the COMPRESSED file as published in sha256sum.txt. Empty string skips the check."
  type        = string
}

variable "services_image_url" {
  description = "Cloud image for the services VM. Any EL9/EL10 qcow2 with cloud-init works."
  type        = string
}

variable "services_image_capacity" {
  description = "Size in bytes of the services image. Set explicitly: the mirrors do not always send Content-Length."
  type        = number
}

variable "image_cache_dir" {
  description = "Directory on the hypervisor holding the downloaded and decompressed bootimage. Reused across applies."
  type        = string
}

variable "work_dir" {
  description = "Directory for the installer, install-config.yaml, the generated Ignition configs and the kubeconfig. Treat as secret: it holds cluster credentials."
  type        = string
}

# ────────────────────────────────── nodes ─────────────────────────────────

variable "nodes" {
  description = <<-EOT
    The cluster, one entry per machine. `role` is bootstrap, master or worker.
    `ip` is required - UPI on libvirt has no DHCP, every node is addressed
    statically through its Ignition config. Everything else falls back to the
    per-role defaults below.
  EOT
  type = map(object({
    role      = string
    ip        = string
    memory    = optional(number)
    vcpu      = optional(number)
    disk_size = optional(number)
  }))

  validation {
    condition     = alltrue([for n in var.nodes : contains(["bootstrap", "master", "worker"], n.role)])
    error_message = "Each node's role must be bootstrap, master or worker."
  }

  validation {
    condition     = length([for n in var.nodes : n if n.role == "bootstrap"]) == 1
    error_message = "Exactly one bootstrap node is required; destroy it with destroy_bootstrap once bootstrapping finishes."
  }

  validation {
    condition     = contains([1, 3], length([for n in var.nodes : n if n.role == "master"]))
    error_message = "A cluster needs 1 or 3 control plane nodes."
  }
}

variable "role_defaults" {
  description = "Per-role sizing applied to any node that does not set its own. OpenShift 4.22 wants 16 GiB and 4 vCPU on a control plane node."
  type = map(object({
    memory    = number
    vcpu      = number
    disk_size = number
  }))
}

variable "masters_schedulable" {
  description = "Run workloads on the control plane. Required for a compact 3-node cluster with no workers."
  type        = bool
}

# ─────────────────────────────── node hardware ────────────────────────────

variable "cpu_mode" {
  description = "libvirt CPU mode. host-passthrough gives the guest the host's flags, which RHCOS wants."
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
  description = "Attach the guest agent channel. RHCOS ships qemu-guest-agent, so libvirt can report addresses."
  type        = bool
}

variable "shutdown_timeout" {
  description = "Seconds to wait for an ACPI shutdown on destroy before pulling the plug. 0 disables the graceful path."
  type        = number
}

variable "autostart" {
  description = "Start the nodes when the hypervisor boots."
  type        = bool
}

# ───────────────────────────── services VM ────────────────────────────────

variable "manage_services_vm" {
  description = "Create the DNS and load balancer VM. Set false when you point api, api-int and *.apps at infrastructure you already run."
  type        = bool
}

variable "services_memory" {
  description = "Memory for the services VM in MiB. dnsmasq and haproxy need very little."
  type        = number
}

variable "services_vcpu" {
  description = "vCPUs for the services VM."
  type        = number
}

variable "services_disk_size" {
  description = "Root disk for the services VM in GiB."
  type        = number
}

variable "services_user" {
  description = "Login user created on the services VM."
  type        = string
}

# ──────────────────────────────── install ─────────────────────────────────

variable "run_installer" {
  description = "Let Terraform run openshift-install and wait for the cluster. False stops after the machines exist, for driving the install by hand."
  type        = bool
}

variable "bootstrap_timeout" {
  description = "How long to wait for bootstrap-complete, as a Go duration, e.g. \"45m\"."
  type        = string
}

variable "install_timeout" {
  description = "How long to wait for install-complete, as a Go duration."
  type        = string
}

variable "destroy_bootstrap" {
  description = "Remove the bootstrap node from the load balancer and destroy it once bootstrapping finishes. Flip this to true and re-apply - that is the UPI step the docs tell you to do by hand."
  type        = bool
}
