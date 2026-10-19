# The mirror serves the bootimage gzipped and libvirt cannot upload a .gz, so
# it is fetched and decompressed once into a cache directory and uploaded from
# there. The Azure stack did the same with curl + gunzip in a null_resource,
# but keyed on `always_run = timestamp()`, which re-downloaded 1.4 GB on every
# single plan. This keys on the URL and checksum instead, so it runs once.
resource "terraform_data" "rhcos_image" {
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
