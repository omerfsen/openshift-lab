# OpenShift test lab on KVM/libvirt

A current OpenShift cluster on one libvirt host, built by Terraform: the
machines, the network, the DNS and load balancer the installer refuses to
create, and the install itself. Roughly 25 minutes from `apply` to a working
console, and all of it comes back out with `terraform destroy`.

Built and verified end to end on 2026-10-20.

## Versions

| | version | note |
|---|---|---|
| **OpenShift** | **4.22.18** | `ocp_version` |
| RHCOS bootimage | **4.22.8** | `rhcos_image_url` - not a typo, see [Three versions](#three-versions-and-why-they-disagree) |
| machine-os the nodes end up on | 10.2 (RHEL 10.2) | written by the machine-config operator on first boot |
| Terraform | >= 1.16 (tested 1.16.5) | |
| `dmacvicar/libvirt` | ~> 0.9.9 | 0.9 is a redesign of the 0.8 schema |
| libvirt / QEMU on the host | 8.0 / 6.2 | the QEMU version matters, see [How Ignition reaches a node](#how-ignition-reaches-a-node) |

### Checking for a newer OpenShift

Ask the update graph, not the mirror's directory listing. The mirror publishes
builds that are in **no channel** - installing one leaves a cluster with no
upgrade path, and the build can be withdrawn:

```bash
curl -sH 'Accept: application/json' \
  'https://api.openshift.com/api/upgrades_info/v1/graph?channel=stable-4.22' |
  jq -r '[.nodes[].version] | sort_by(split(".")|map(tonumber)) | last'
```

Set `ocp_version` to what that prints. The **bootimage follows its own
cadence** and will not match - check which one the installer actually wants:

```bash
openshift-install coreos print-stream-json |
  jq -r '.architectures.x86_64.artifacts.qemu.formats["qcow2.gz"].disk | .location, .sha256'
```

and put those two values in `rhcos_image_url` and `rhcos_image_sha256`. For the
`config-drive` delivery take the **openstack** artifact instead of `qemu`; a
precondition refuses to build if the pair disagrees.

## Step by step

### 1. Check the host can take it

| | this lab | why |
|---|---|---|
| RAM | **64 GiB free** while bootstrapping, 48 after | 16 GiB per control plane node is OpenShift's floor; below it the install does not fail, it just never converges |
| disk | ~110 GiB at peak in the libvirt pool | thin overlays, but they grow as operators land |
| CPU | 4 vCPU per node | |
| tools | `terraform`, `genisoimage`, `virsh`, `curl`, `jq` | |

```bash
free -g; df -h /var/lib/libvirt/images; virsh net-list
```

The bootstrap node is temporary - it is destroyed in step 7 - so if RAM is
tight, shrink it rather than the masters:

```hcl
role_defaults = {
  bootstrap = { memory = 10240, vcpu = 4, disk_size = 120 }   # transient
  master    = { memory = 16384, vcpu = 4, disk_size = 120 }   # leave this alone
  worker    = { memory = 8192, vcpu = 2, disk_size = 120 }
}
```

### 2. Get a pull secret

From <https://console.redhat.com/openshift/install/pull-secret> - a free Red Hat
account, no subscription. Save it somewhere outside the repo:

```bash
install -m 600 /dev/null ~/pull-secret.json
# paste into it
jq -r '.auths | keys[]' ~/pull-secret.json     # expect 4 registries
```

### 3. Pick a network

Two options, and joining an existing one is usually right:

```hcl
create_network       = false              # join a network that already exists
network_name         = "default"
machine_network_cidr = "192.168.122.0/24"
gateway_ip           = "192.168.122.1"
```

Joining means no route to publish, no `virsh net-edit` (which needs a network
restart and drops every VM on that bridge), and `destroy` never touches a
network it did not create. Set `create_network = true` with its own CIDR to
have this stack build and own one instead.

Pick addresses outside the network's DHCP range, and check nothing answers:

```bash
virsh net-dumpxml default | grep -A2 '<dhcp>'
for i in 39 40 41 42 60; do ping -c1 -W1 192.168.122.$i >/dev/null && echo ".$i IN USE"; done
```

A defined-but-stopped VM claims its address the moment it starts, so check
`virsh list --all`, not just what replies today.

### 4. Create the DNS records

Three records, all pointing at `services_ip` - the load balancer, **never** at
a master. During bootstrapping the API backend includes the bootstrap node,
which is the whole reason the load balancer exists.

| record | type | value |
|---|---|---|
| `api.<cluster>.<base_domain>` | A | services_ip |
| `api-int.<cluster>.<base_domain>` | A | services_ip |
| `*.apps.<cluster>.<base_domain>` | A | services_ip |

After step 5 you can generate them from the config, so they cannot drift from
the addresses the machines actually get:

```bash
terraform output -raw bind_zone > ocp.zone     # importable at most DNS providers
```

Two traps, both of which cost an afternoon here:

- **An `NS` record for the subdomain shadows every record beneath it.** If you
  once delegated `ocp.example.com` to a helper node, the A records you add at
  the provider are ignored and every lookup SERVFAILs. Delete the NS records.
- An `NS` must point at a name with an **A record**, never a CNAME (RFC 2181),
  and never at an RFC1918 address if the internet has to resolve it.

Verify from outside your own resolver before going further:

```bash
dig +short api.ocp.example.com @1.1.1.1
dig +short anything.apps.ocp.example.com @1.1.1.1
```

### 5. Write terraform.tfvars

```bash
cp terraform.tfvars.example terraform.tfvars
chmod 600 terraform.tfvars        # it will hold the pull secret
```

Every variable is required - none carries a default, so a value you forget
fails at plan time rather than taking one buried in the code. The ones that
always need changing: `cluster_name`, `base_domain`, `pull_secret`,
`ssh_authorized_keys`, the addresses in `nodes`, `services_ip`, and `pool`.

```bash
terraform init
terraform plan        # ~24 resources on a compact cluster
```

### 6. Build it

```bash
terraform apply
```

In order: the bootimage is fetched and decompressed once, a base volume is
uploaded, the services VM comes up with haproxy, `openshift-install` generates
the Ignition configs, four machines boot, and Terraform waits for
`bootstrap-complete`. About 20 minutes.

Watch it from three angles:

```bash
virsh console bootstrap                       # Ctrl-] to exit
curl -s 'http://<services_ip>:9000/;csv' | cut -d, -f1,2,18   # haproxy backends
du -h /var/lib/libvirt/images/master0.qcow2   # a node that is working, grows
```

The one line that matters on a node's console is the Ignition verdict:

```
Ignition: user-provided config was applied     <- good
Ignition: no config provided by user           <- it booted with nothing; see below
```

### 7. Remove the bootstrap node

Once `bootstrap-complete` passes - this is the single manual gate a
user-provisioned install leaves you:

```hcl
destroy_bootstrap = true
```

```bash
terraform apply       # removes the bootstrap machine, then waits for install-complete
```

It frees its RAM, and the installer prints the console URL and the `kubeadmin`
password when it finishes.

### 8. Log in

```bash
export KUBECONFIG=<work_dir>/install/auth/kubeconfig
oc get clusterversion        # Available=True means done
oc get co                    # expect all Available, none Degraded
```

Console at `https://console-openshift-console.apps.<cluster>.<base_domain>`,
user `kubeadmin`, password in `<work_dir>/install/auth/kubeadmin-password`.
Full detail, including the HSTS trap, in [Getting in](#getting-in).

To merge it into an existing `~/.kube/config` rather than overwrite it:

```bash
cp ~/.kube/config ~/.kube/config.bak
cp <work_dir>/install/auth/kubeconfig /tmp/new-kc
oc --kubeconfig /tmp/new-kc config rename-context admin ocp-lab
KUBECONFIG=~/.kube/config:/tmp/new-kc oc config view --flatten > /tmp/merged
mv /tmp/merged ~/.kube/config && chmod 600 ~/.kube/config && rm /tmp/new-kc
oc config use-context ocp-lab
```

### 9. Tear it down

```bash
terraform destroy
```

Takes the machines, the volumes, the services VM, and the network if this stack
created it. `work_dir` survives on purpose - it holds the kubeconfig and the
kubeadmin password, so delete it deliberately. The DNS records are yours too.

## Reference

Everything below is the why behind the steps above - read it when something
behaves oddly, or before changing a default.

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

## Getting in

### The web console

| | |
|---|---|
| URL | `https://console-openshift-console.apps.<cluster_name>.<base_domain>` |
| username | `kubeadmin` |
| password | `cat <work_dir>/install/auth/kubeadmin-password` |

It works from anywhere that can route to `services_ip` and resolve the
wildcard, so over a VPN that already carries the machine network there is
nothing to forward or tunnel. Expect a certificate warning: the console uses
the cluster's self-signed ingress certificate until you install a real one.

The console and `authentication` operators come up late - during
`install-complete`, after the control plane has pivoted off the bootstrap
machine. Blank rows in `oc get co` before that are normal, not a fault.

### The CLI

```bash
export KUBECONFIG=<work_dir>/install/auth/kubeconfig
<work_dir>/tools/oc get co
```

`terraform output credentials` prints both paths and the exact `export` line.
Treat the whole `auth/` directory as secret: it holds cluster-admin
credentials, and `kubeadmin` never expires on its own.

### SSH

Two operating systems, so two users:

| host | user | why |
|---|---|---|
| the nodes | **`core`** | RHCOS creates exactly one user, and the `sshKey` from `install-config.yaml` goes to it |
| services VM | `services_user` (e.g. `ocpadmin`) | AlmaLinux, created by cloud-init |

```bash
ssh core@master0.<cluster_name>.<base_domain>
ssh core@192.168.122.40
```

There is no account named after the cluster or the project; `ssh ocp@...`
fails with `Permission denied (publickey)` because that user does not exist,
not because the key is wrong.

Rebuilding a node regenerates its host keys, so a later connection to a
reused address warns that the host identification changed. `ssh-keygen -R
<address>` clears it - expected after a rebuild.

### Reading a node's console

Every domain gets a serial console, which is the only way in before SSH
exists - and the only place the Ignition verdict is printed:

```bash
virsh console master0          # Ctrl-] to exit
```

Only one client can hold it at a time, so a forgotten `virsh console` blocks
the next one. For a boot you can read afterwards, give the domain a serial log
instead:

```xml
<serial type='pty'>
  <log file='/var/log/libvirt/serial/master0.log' append='off'/>
</serial>
```

### Expected noise, not errors

On the `config-drive` delivery each node logs, on first boot:

```
Ignition: fetching configuration for http://169.254.169.254/openstack/latest/user_data: unable to fetch resource in time
```

That is the `openstack` platform trying the cloud metadata service as well as
the config drive, because on a real OpenStack cloud either may be present.
There is no metadata service on libvirt, the attempt times out, and Ignition
falls back to the drive. The line that matters is the one above it:

```
Ignition: user-provided config was applied
```

It costs a few seconds per first boot and nothing else.

## Adding a worker

A compact cluster has none: `masters_schedulable = true` removes the control
plane taint and the masters run the workloads. That is a supported topology and
the right one for a lab - three fewer machines, and on a host with 59 GiB free
it was the difference between fitting and not.

Workers ship **written and disabled**, so adding one is a word:

```hcl
"worker0" = { role = "worker", ip = "192.168.122.50", enabled = true }
```

then `terraform apply`. Start with `worker0` alone; it exercises the whole path
for the cost of one machine.

**Then approve its certificates.** This is the step a cloud does for you and
UPI does not. A new node submits two CSRs - one to join, one for its kubelet
serving certificate - and nothing signs them automatically:

```bash
oc get csr -o name | xargs oc adm certificate approve     # client CSR, node appears
oc get csr -o name | xargs oc adm certificate approve     # serving CSR, a minute later
oc get nodes
```

Run it twice, a minute apart: the second CSR only exists once the first is
approved and the node has registered. A worker stuck `NotReady`, or absent from
`oc get nodes` entirely, is almost always an unapproved CSR rather than a
broken machine.

Once workers carry the load you can give the control plane back to itself:

```hcl
masters_schedulable = false
```

That reinstates the taint and evicts workloads from the masters, so only do it
with somewhere for them to go.

### What `enabled` does and does not do

`enabled = false` leaves the entry in `nodes` but builds nothing: no domain, no
disks, no config drive, no DNS record in the generated zone. It is not a
power switch - a machine that already exists is **destroyed** when you disable
it. To stop a node without losing it, use `virsh shutdown`.

Validations count only enabled nodes, so the 1-or-3 control plane rule and the
exactly-one-bootstrap rule describe the cluster that will actually exist.

### Choosing MAC addresses

Every node's MAC is derived from its name, deterministically, in one place -
`modules/node/main.tf`, `local.mac`. The same value goes into the domain's NIC
and into the Ignition NetworkManager keyfile, which matches on it, so the two
can never disagree.

Deriving rather than randomising means a node keeps its address across a
destroy and rebuild, so anything keyed to it - a DHCP reservation, a firewall
rule, a switch ACL - keeps working.

Override it per node when something outside this stack already owns the number:

```hcl
"master0" = { role = "master", ip = "192.168.122.40", mac = "52:54:00:ab:cd:ef" }
```

Keep the `52:54:00` prefix: it is QEMU's registered range, and straying outside
it risks colliding with real hardware on a bridged network.

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

**A post-install apply must be a no-op, and that takes care.**
`openshift-install create ignition-configs` *deletes* `install-config.yaml`.
Written inside `install_dir`, Terraform would see its own file missing on every
later plan, recreate it, and - because a new resource's `content_sha256` is
unknown at plan time - cascade into replacing the Ignition configs and
overwriting `auth/kubeconfig` with credentials that no longer match the running
cluster. So it is written one directory up and copied in. If a plan ever wants
to replace `terraform_data.ignition` on a healthy cluster, stop and find out
why before applying.

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
