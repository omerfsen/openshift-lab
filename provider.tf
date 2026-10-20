terraform {
  # A floor, not a pin. The Azure stack this was adapted from used "= 1.11.4",
  # which refuses to run under anything else, including every release since.
  # Tested on 1.16.5.
  required_version = ">= 1.16.0"

  required_providers {
    libvirt = {
      source = "dmacvicar/libvirt"
      # 0.9.x is a redesign: HCL maps almost 1:1 onto libvirt XML. There is no
      # automated migration from the 0.8 schema, so pin the minor.
      version = "~> 0.9.9"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}
