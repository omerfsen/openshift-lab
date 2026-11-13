# The bootimage has to belong to the OS stream the cluster is installed with:
# RHEL 10 for rhel-10, RHEL 9 for rhel-9. The installer knows exactly which
# files those are, by checksum, so this asks it rather than trusting a URL.
# A mismatch fails here, before the 1.4 GB download, instead of as a node that
# boots one RHEL and is told to become the other.
resource "terraform_data" "bootimage_check" {
  triggers_replace = [var.ocp_version, var.os_image_stream, var.rhcos_image_sha256]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-euo", "pipefail", "-c"]
    command     = <<-EOT
      if [[ -z '${var.rhcos_image_sha256}' ]]; then
        echo "WARNING: rhcos_image_sha256 is empty, the bootimage is not checked against the installer"
        exit 0
      fi
      if '${local.installer}' coreos print-stream-json --stream '${var.os_image_stream}' \
          | grep -qF '"sha256":"${var.rhcos_image_sha256}"'; then
        echo "bootimage is in the ${var.os_image_stream} stream of openshift-install ${var.ocp_version}"
      else
        echo "ERROR: rhcos_image_sha256 is not a bootimage in the ${var.os_image_stream} stream of openshift-install ${var.ocp_version}." >&2
        echo "List the right ones with: openshift-install coreos print-stream-json --stream ${var.os_image_stream}" >&2
        exit 1
      fi
    EOT
  }

  depends_on = [terraform_data.tools]
}

# The mirror serves the bootimage gzipped and libvirt cannot upload a .gz, so
# it is fetched and decompressed once into a cache directory and uploaded from
# there. The Azure stack did the same with curl + gunzip in a null_resource,
# but keyed on `always_run = timestamp()`, which re-downloaded 1.4 GB on every
# single plan. This keys on the URL and checksum instead, so it runs once.
# The bootimage and the delivery mechanism are not independent choices: the
# kernel in each image hard-codes ignition.platform.id, which decides where
# Ignition looks. Pairing them wrongly produces a node that boots cleanly with
# no config at all, which is a slow and confusing way to fail.
resource "terraform_data" "rhcos_image" {
  lifecycle {
    precondition {
      condition = (
        var.ignition_delivery == "config-drive" ? can(regex("openstack", var.rhcos_image_url)) : can(regex("qemu", var.rhcos_image_url))
      )
      error_message = "ignition_delivery = \"${var.ignition_delivery}\" needs the ${var.ignition_delivery == "config-drive" ? "openstack" : "qemu"} bootimage, but rhcos_image_url does not name it."
    }
  }

  triggers_replace = [var.rhcos_image_url, var.rhcos_image_sha256, local.rhcos_qcow2]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-euo", "pipefail", "-c"]
    command     = <<-EOT
      mkdir -p '${var.image_cache_dir}'
      if [[ -s '${local.rhcos_qcow2}' ]]; then
        echo "bootimage already cached: ${local.rhcos_qcow2}"
        exit 0
      fi
      echo "fetching ${var.rhcos_image_url}"
      curl -fL --retry 3 -o '${local.rhcos_qcow2}.gz.part' '${var.rhcos_image_url}'
      if [[ -n '${var.rhcos_image_sha256}' ]]; then
        echo '${var.rhcos_image_sha256}  ${local.rhcos_qcow2}.gz.part' | sha256sum -c -
      else
        echo "WARNING: rhcos_image_sha256 is empty, the download is unverified"
      fi
      mv '${local.rhcos_qcow2}.gz.part' '${local.rhcos_qcow2}.gz'
      gunzip -f '${local.rhcos_qcow2}.gz'
      test -s '${local.rhcos_qcow2}'
    EOT
  }

  depends_on = [terraform_data.bootimage_check]
}

locals {
  # Named after the file on the mirror, minus the .gz, so two RHCOS versions
  # can sit in the cache side by side.
  rhcos_basename = replace(basename(var.rhcos_image_url), ".gz", "")
  rhcos_qcow2    = "${var.image_cache_dir}/${local.rhcos_basename}"
}

# One base volume for the whole cluster. Every node's root disk is a
# copy-on-write overlay on it, so three control plane nodes cost one image plus
# their own writes.
resource "libvirt_volume" "rhcos" {
  name = local.rhcos_basename
  pool = var.pool

  target = {
    format = { type = "qcow2" }
  }

  create = {
    content = { url = "file://${local.rhcos_qcow2}" }
  }

  depends_on = [terraform_data.rhcos_image]
}

# The services VM runs an ordinary cloud image, not RHCOS: it needs a package
# manager and a writable filesystem to host dnsmasq and haproxy.
resource "libvirt_volume" "services_base" {
  count = var.manage_services_vm ? 1 : 0

  name     = "${var.cluster_name}-services-base.qcow2"
  pool     = var.pool
  capacity = var.services_image_capacity

  target = {
    format = { type = "qcow2" }
  }

  create = {
    content = { url = var.services_image_url }
  }
}
