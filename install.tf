locals {
  mirror_clients = "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${var.ocp_version}"
  tools_dir      = "${var.work_dir}/tools"
  install_dir    = "${var.work_dir}/install"
  installer      = "${local.tools_dir}/openshift-install"
  oc             = "${local.tools_dir}/oc"
}

# openshift-install and oc, pinned to the release being installed. A mismatched
# installer writes Ignition configs for a different payload, so this is keyed
# on the version and re-runs when it changes.
resource "terraform_data" "tools" {
  triggers_replace = [var.ocp_version]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-euo", "pipefail", "-c"]
    command     = <<-EOT
      mkdir -p '${local.tools_dir}'
      cd '${local.tools_dir}'
      curl -fL --retry 3 -o installer.tar.gz '${local.mirror_clients}/openshift-install-linux-${var.ocp_version}.tar.gz'
      curl -fL --retry 3 -o client.tar.gz    '${local.mirror_clients}/openshift-client-linux-${var.ocp_version}.tar.gz'
      tar xzf installer.tar.gz openshift-install
      tar xzf client.tar.gz oc kubectl
      rm -f installer.tar.gz client.tar.gz
      ./openshift-install version
    EOT
  }
}

# install-config.yaml is CONSUMED by `create ignition-configs` - the installer
# deletes it. So Terraform writes it one directory up, outside install_dir, and
# the step below copies it in. Writing it where the installer can eat it makes
# every later plan want to recreate it, which cascades into regenerating the
# Ignition configs and overwriting auth/kubeconfig with credentials that no
# longer match the running cluster.
resource "local_sensitive_file" "install_config" {
  filename        = "${var.work_dir}/install-config.yaml"
  file_permission = "0600"

  content = templatefile("${path.module}/templates/install-config.yaml.tftpl", {
    cluster_name         = var.cluster_name
    base_domain          = var.base_domain
    machine_network_cidr = var.machine_network_cidr
    cluster_network_cidr = var.cluster_network_cidr
    host_prefix          = var.cluster_network_host_prefix
    service_network_cidr = var.service_network_cidr
    network_type         = var.network_type
    fips                 = var.fips
    master_replicas      = local.node_count["master"]
    # Always 0, however many workers exist. A user-provisioned install owns its
    # own machines; any other number makes the installer emit machinesets for a
    # machine API that is not driving anything here, and the compute pool would
    # then disagree with the machines this stack actually built.
    worker_replicas = 0
    # jsonencode, not the raw value: the pull secret starts with '{', and YAML
    # reads that as a flow mapping rather than a string. Quoting it makes it a
    # scalar. trimspace because a trailing newline from the file would land
    # inside the quotes.
    pull_secret = jsonencode(trimspace(var.pull_secret))
    # Two spaces, because every line after the first in the `sshKey: |` block
    # has to be indented to stay inside it. The first line's indent comes from
    # the template.
    ssh_key = join("\n  ", var.ssh_authorized_keys)
  })
}

# Generates bootstrap.ign, master.ign and worker.ign.
#
# master.ign and worker.ign are ~2 KB pointer configs aimed at
# api-int:22623; bootstrap.ign is the self-contained ~300 KB one. All three go
# to the nodes through fw_cfg, so nothing has to be served over HTTP the way
# the bare-metal UPI documentation assumes.
#
# The certificates inside bootstrap.ign expire 24 hours after generation. If an
# install stalls past that, taint this resource rather than reusing the files.
resource "terraform_data" "ignition" {
  triggers_replace = [
    var.ocp_version,
    local_sensitive_file.install_config.content_sha256,
    var.masters_schedulable,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-euo", "pipefail", "-c"]
    command     = <<-EOT
      mkdir -p '${local.install_dir}'
      cd '${local.install_dir}'
      # The installer eats its copy; Terraform's stays put one level up.
      cp -f '${local_sensitive_file.install_config.filename}' install-config.yaml
      '${local.installer}' create manifests --dir .
      # A compact cluster has no workers, so the control plane has to be
      # schedulable or nothing can be placed. The installer defaults this to
      # true only when it knows the compute replica count is zero.
      sed -i 's/^\( *mastersSchedulable:\).*/\1 ${var.masters_schedulable}/' \
        manifests/cluster-scheduler-02-config.yml
      grep -n mastersSchedulable manifests/cluster-scheduler-02-config.yml
      '${local.installer}' create ignition-configs --dir .
      ls -l bootstrap.ign master.ign worker.ign
    EOT
  }

  depends_on = [terraform_data.tools]
}

# Read back at apply time, after the installer has written them.
data "local_file" "ignition" {
  for_each = toset(["bootstrap", "master", "worker"])
  filename = "${local.install_dir}/${each.key}.ign"

  depends_on = [terraform_data.ignition]
}

# ──────────────────────────────── the waits ───────────────────────────────

# Bootstrapping is finished when the control plane has taken over from the
# bootstrap node. Only after this does destroying the bootstrap node make sense.
resource "terraform_data" "wait_bootstrap" {
  count = var.run_installer ? 1 : 0

  triggers_replace = [terraform_data.ignition.id]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-euo", "pipefail", "-c"]
    command     = <<-EOT
      # wait-for has its own internal deadline; this is the outer one, so a
      # stuck install fails the apply instead of hanging it.
      timeout ${var.bootstrap_timeout} '${local.installer}' wait-for bootstrap-complete \
        --dir '${local.install_dir}' --log-level=info
    EOT
  }

  depends_on = [module.node]
}

resource "terraform_data" "wait_install" {
  count = var.run_installer && var.destroy_bootstrap ? 1 : 0

  triggers_replace = [terraform_data.ignition.id]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-euo", "pipefail", "-c"]
    command     = <<-EOT
      timeout ${var.install_timeout} '${local.installer}' wait-for install-complete \
        --dir '${local.install_dir}' --log-level=info
    EOT
  }

  depends_on = [module.node]
}
