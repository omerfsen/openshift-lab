output "cluster" {
  description = "What was built, and where."
  value = {
    name        = var.cluster_name
    domain      = local.cluster_domain
    api         = "https://api.${local.cluster_domain}:6443"
    console     = "https://console-openshift-console.${local.apps_domain}"
    ocp_version = var.ocp_version
    rhcos_image = local.rhcos_basename
  }
}

output "nodes" {
  description = "Name, role, address, UUID and MAC for each live machine."
  value = {
    for name, m in module.node : name => {
      role = var.nodes[name].role
      fqdn = m.fqdn
      ip   = m.ip
      uuid = m.uuid
      mac  = m.mac
    }
  }
}

output "services_vm" {
  description = "The DNS and load balancer VM, or null when you provide your own."
  value = var.manage_services_vm ? {
    name  = local.services_name
    ip    = var.services_ip
    ssh   = "ssh ${var.services_user}@${var.services_ip}"
    stats = "http://${var.services_ip}:9000/"
  } : null
}

output "dns_records" {
  description = "What has to resolve for this cluster. Already served by the services VM; listed so they can be reproduced on infrastructure you run yourself."
  value = merge(
    {
      "api.${local.cluster_domain}"     = var.services_ip
      "api-int.${local.cluster_domain}" = var.services_ip
      "*.${local.apps_domain}"          = var.services_ip
    },
    { for name, n in var.nodes : "${name}.${local.cluster_domain}" => n.ip },
  )
}

output "console" {
  description = "Attach to a machine's serial console to watch Ignition and the bootstrap run."
  value       = { for name, _ in local.live_nodes : name => "virsh --connect ${var.libvirt_uri} console ${name}" }
}

output "kubeconfig" {
  description = "Where the installer leaves cluster credentials. Treat the whole directory as secret."
  value = {
    kubeconfig = "${local.install_dir}/auth/kubeconfig"
    kubeadmin  = "${local.install_dir}/auth/kubeadmin-password"
    oc         = local.oc
    export     = "export KUBECONFIG=${local.install_dir}/auth/kubeconfig"
  }
}

output "next_step" {
  description = "The one manual decision UPI leaves you."
  value       = var.destroy_bootstrap ? "Bootstrap is destroyed; the cluster is on its own." : "Once `openshift-install wait-for bootstrap-complete` passes, set destroy_bootstrap = true in terraform.tfvars and apply again."
}
