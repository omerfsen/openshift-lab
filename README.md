# OpenShift on KVM/libvirt, user-provisioned

Builds a full OpenShift cluster on a single libvirt host with Terraform: the
machines, the network they sit on, the DNS and the load balancer the installer
refuses to create for you, and the install itself.

```bash
cp terraform.tfvars.example terraform.tfvars   # edit: pull secret, ssh key, sizing
terraform init && terraform apply              # bootstrap + control plane come up
# ... wait-for bootstrap-complete passes ...
#     set destroy_bootstrap = true
terraform apply                                # bootstrap is removed, install finishes
```

## What a user-provisioned install actually asks of you

`platform: none` tells the installer to create nothing. It hands you three
Ignition configs and a list of things that must already exist:

| It expects | Here |
|---|---|
| machines running RHCOS, each with the right Ignition config | `modules/node`, one call per entry in `nodes` |
| static addressing, since there is no cloud metadata service | a NetworkManager keyfile merged into each node's Ignition |
| `api`, `api-int` and `*.apps` DNS | your own zone, or dnsmasq on the services VM - see below |
| a load balancer on 6443, 22623, 80 and 443 | haproxy on the services VM |
| the bootstrap node removed once it is done | `destroy_bootstrap = true`, then apply |

The point of this stack is that all of it is in `terraform destroy`.

## Layout

| Path | What |
|---|---|
| `provider.tf` | provider and version constraints |
| `variables.tf` | every input, typed and described, no defaults |
| `terraform.tfvars` | every value - the only file you normally edit, and gitignored |
| `main.tf` | the locals that split `nodes` by role |
| `network.tf` | the cluster's own libvirt network, NAT, no DHCP |
| `images.tf` | fetch and decompress the RHCOS bootimage, upload it once; checks it matches `ignition_delivery` |
| `install.tf` | openshift-install, install-config.yaml, the Ignition configs, the waits |
| `services.tf` | the DNS and load balancer VM |
| `nodes.tf` | one `module.node` per machine |
| `outputs.tf` | addresses, consoles, the DNS contract, where the kubeconfig landed |
| `modules/node/` | one machine: overlay disk, merged Ignition, its config drive or fw_cfg entry, the domain |
| `templates/` | install-config, dnsmasq, haproxy, the services VM's cloud-init |

Variables carry no defaults on purpose: a value you forgot fails at plan time
instead of quietly taking one that was buried in the code.

## What you need

| | |
|---|---|
| Terraform | >= 1.16 (tested on 1.16.5) |
| Provider | `dmacvicar/libvirt` ~> 0.9.9 |
| Hypervisor | libvirt with a storage pool; **Terraform must run on it** (see below) |
| RAM | 16 GiB per control plane node plus 16 for bootstrap: **64 GiB** for a compact cluster while bootstrapping, 48 after |
| Disk | 120 GiB per node, thin - the overlays start at ~200 KiB and grow |
| Pull secret | free, from <https://console.redhat.com/openshift/install/pull-secret> |

A compact three-node cluster is the default: three control plane nodes, no
workers, `masters_schedulable = true`. Add `worker` entries to `nodes` and set
`masters_schedulable = false` for a standard layout.

## How Ignition reaches a node

RHCOS has no cloud-init. Everything a node is — its hostname, its address, its
SSH keys, the entire control plane on the bootstrap machine — arrives as one
Ignition config read once, on first boot. If it does not arrive, the node still
boots perfectly: a login prompt, a DHCP address, a hostname taken from the
lease, and nothing of yours. **That is the failure mode to recognise**, because
nothing errors.

The console tells you which happened:

```
Ignition: no config provided by user                      <- it arrived with nothing
fetched user config from "openstack"                      <- it worked
```

Two mechanisms, set with `ignition_delivery`. They are not interchangeable at
runtime: each RHCOS bootimage hard-codes `ignition.platform.id` in its kernel
arguments, which decides where Ignition looks. A precondition refuses to build
anything if the pair does not match.

| | `config-drive` (default) | `fw_cfg` |
|---|---|---|
| bootimage | **openstack** | **qemu** |
| `ignition.platform.id` | `openstack` | `qemu` |
| how it travels | an ISO labelled `config-2`, attached as a cdrom | QEMU's firmware config interface |
| where the guest reads it | `openstack/latest/user_data` on the mounted ISO | `/sys/firmware/qemu_fw_cfg/by_name/opt/com.coreos/config` |
| extra host tooling | `genisoimage` | none |
| works on QEMU 6.2 / Ubuntu 22.04 | **yes** | **no** |

### Why config-drive is the default

`fw_cfg` is the tidier mechanism and the one the libvirt provider's own
documentation shows: no ISO, no extra tool, one `<sysinfo type='fwcfg'>`
element. It is the better choice when it works.

It silently does not work on QEMU 6.2 as shipped in Ubuntu 22.04. Everything on
the host looks right — libvirt emits the correct XML, the qemu command line
carries `-fw_cfg name=opt/com.coreos/config,file=...`, the file is present and
readable inside qemu's own mount namespace, and there is no AppArmor denial.
Inside the guest, `/sys/firmware/qemu_fw_cfg/` is **empty**: no `by_name`, not
even `rev`, with the driver built in. Both an RHCOS 5.14 kernel and an
AlmaLinux 6.12 kernel on the same host see the same nothing, so it is the host
that cannot present the interface. Ignition reports:

```
ignition[687]: QEMU firmware config was not found. Ignoring...
```

and the node boots with no configuration at all. Passing the same argument
through `<qemu:commandline>` instead changes nothing, because the delivery form
was never the problem.

A config drive avoids the question entirely: it is an ordinary ISO on an
ordinary SATA cdrom, and a guest that can read a CD can read its Ignition.

**The lesson worth keeping:** an earlier probe proved that libvirt *emits* the
right fw_cfg XML and treated that as proof the mechanism worked. It is not the
same claim. "The provider generates correct XML" and "the guest receives the
config" are two different things, and only the second one matters. Probe to the
point where the guest reports success, not to the point where the host looks
correct.

### Switching back

```hcl
ignition_delivery  = "fw_cfg"
rhcos_image_url    = ".../rhcos-4.22.8-x86_64-qemu.x86_64.qcow2.gz"
rhcos_image_sha256 = "b1c733a288f0980e527a492b6d604621545fe86aadc0189511964ee867a09904"
```

Worth doing on a host with a newer QEMU: it drops the ISO, the staging
directory and the `genisoimage` dependency. Check it first with one node and
read the console — `fetched user config` means yes, `no config provided by
user` means no.

## Three versions, and why they disagree

An install involves three RHCOS/OpenShift version numbers that look like they
should match and never do:

| | version here | what it is |
|---|---|---|
| installer and payload | **4.22.18** | the release being installed - `ocp_version` |
| **bootimage** | **4.22.8** | what the machines first boot - `rhcos_image_url` |
| machine-os | **10.2.20261006-0** | what every node actually ends up running |

**The bootimage is not versioned with the payload.** Red Hat publishes
bootimages on their own cadence, and the whole 4.22 stream has exactly two:

```
rhcos/4.22/          ->  4.22.0/   4.22.8/
rhcos/4.22/4.22.18/  ->  HTTP 404, there is no such thing
rhcos/latest/        ->  rhcos-4.22.8-x86_64-qemu.x86_64.qcow2.gz
```

So 4.22.8 is not a stale pin, it is the newest bootimage that exists. Do not
go looking for one that matches `ocp_version`; it will not be there.

**Confirm it by checksum, not by name.** The installer states which bootimage
it expects, under a different naming scheme again - the RHEL stream version:

```bash
openshift-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.qemu'
#   release: 9.8.20260715-1
#   sha256:  b1c733a288f0980e527a492b6d604621545fe86aadc0189511964ee867a09904
```

That digest is the same one `rhcos/4.22/4.22.8/sha256sum.txt` lists for
`rhcos-4.22.8-x86_64-qemu.x86_64.qcow2.gz`. One artifact, three names:
`4.22.8` on the OCP mirror, `9.8.20260715-1` in the stream metadata, and
RHEL 9.8 underneath. `rhcos_image_sha256` pins exactly that file, which is why
the variable exists.

**And it is thrown away almost immediately.** The bootimage only has to boot
far enough to run Ignition. The machine-config operator then writes the
payload's own machine-os to every node - 10.2, RHEL 10 based - on first boot.
A node spends minutes on RHEL 9.8 and the rest of its life on RHEL 10.2, which
is why a bootimage ten patch releases "behind" costs nothing.

If you bump `ocp_version`, re-run the `print-stream-json` check above before
assuming the bootimage URL still applies.

## Things that will catch you

**This stack has to run on the hypervisor.** `libvirt_ignition` writes the
config to `/tmp/terraform-provider-libvirt-ignition/` on the machine running
Terraform, and libvirtd reads it from that path when the domain starts. A
remote `qemu+ssh://` URI puts the file on the wrong machine. It also means a
host reboot between `apply` and a node's first boot loses the file: re-apply.

**Ignition delivery is a choice, and the default is not the obvious one.**
See "How Ignition reaches a node" above: `fw_cfg` is tidier and is what the
provider documents, but it depends on the host's QEMU exposing an interface
that QEMU 6.2 on Ubuntu 22.04 does not. `config-drive` is the default because
it works on any host. Either way nothing is served over HTTP, which is the part
of the bare-metal UPI procedure this replaces.

**`master.ign` and `worker.ign` are pointer configs**, about 2 KB, aimed at
`api-int:22623`. Only `bootstrap.ign` is self-contained, at around 300 KB. The
per-node address and hostname are merged into whichever one applies - merged,
not replaced, because overwriting `storage.files` on the bootstrap config
produces a machine that boots into nothing.

**The certificates inside `bootstrap.ign` expire 24 hours after generation.**
If an install stalls past that, taint `terraform_data.ignition` and apply
again; reusing the files produces failures that look like clock skew.

**The bootstrap node stays in the haproxy backend list after it is destroyed.**
The documented procedure is to edit it out by hand. Leaving it listed reaches
the same place: the health check fails, the backend goes DOWN, nothing is sent
to it - and no config is re-rendered at the most fragile moment of the install.

**The bootimage is not what ends up running.** RHCOS 4.22.8 boots the machines;
the machine-config operator then replaces it with the release payload's own
RHCOS - 10.2, i.e. RHEL 10 based, for 4.22.18.

## Where the cluster's DNS lives

Three choices, set with `manage_cluster_dns` and `cluster_dns_forward_to`.

**Your existing DNS holds the zone** (`manage_cluster_dns = false`). The
services VM becomes a load balancer and nothing else - no dnsmasq package, no
config, no service. Add three records at whatever already serves the domain,
all pointing at `services_ip`:

| record | type | value |
|---|---|---|
| `api.<cluster>.<base_domain>` | A | the services VM |
| `api-int.<cluster>.<base_domain>` | A | the services VM |
| `*.apps.<cluster>.<base_domain>` | A | the services VM |

`api` and `api-int` point at the load balancer, never at a master: during
bootstrapping its backend list includes the bootstrap node, which is the whole
reason it is there. Node A records and their PTRs are optional but worth
adding - a node whose PTR does not resolve shows up under the wrong name in
`oc get nodes`.

Then `node_nameserver` must be a resolver that can see those records.
`192.168.126.1` - the cluster network's own libvirt dnsmasq, which forwards
upstream - is usually the right answer, and means this stack runs no DNS at all.

**A BIND or similar you already run** (`manage_cluster_dns = true`,
`cluster_dns_forward_to = "<ip>#<port>"`). The services VM forwards the cluster
domain there instead of answering for it, so the zone stays in one place and
outlives the VM. Nodes point at the services VM.

**Self-contained** (`manage_cluster_dns = true`, `cluster_dns_forward_to = ""`).
dnsmasq on the services VM is authoritative for the domain, including the
`*.apps` wildcard. Nothing outside the stack is needed, and `terraform destroy`
takes the DNS with it.

## Bringing your own load balancer too

Set `manage_services_vm = false` and point `services_ip` at your own. The
`dns_records` output lists exactly what has to resolve, and the load balancer
needs 6443 and 22623 across the bootstrap and control plane nodes, and 80 and
443 across whatever runs the router.

## Teardown

```bash
terraform destroy
```

Takes the machines, the volumes, the network and the services VM. The
installer's working directory under `work_dir` is left alone - it holds the
kubeconfig and the kubeadmin password, so remove it deliberately.
