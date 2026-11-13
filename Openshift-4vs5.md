# OpenShift 4 vs 5

What changed between the last 4.x release this repo targeted, **4.22.22**, and
**5.0.1**, and what each change meant for this lab. The 4.22.22 state of this
lab is the
[`openshift-4.22.22`](https://github.com/omerfsen/openshift-lab/releases/tag/openshift-4.22.22)
tag.

Most of this was measured, not read: both installers and both release payloads
were downloaded from the public mirror and compared directly (see
[How this was measured](#how-this-was-measured)). Where something comes only
from Red Hat's announcement, it says so.

## At a glance

| | 4.22.22 | 5.0.1 |
|---|---|---|
| Kubernetes (`oc adm release info`) | 1.35.9 | 1.36.5 |
| kubectl | 1.35.2 | 1.36.2 |
| CRI-O | - | 1.36 (Red Hat announcement) |
| Default node OS | **RHCOS 9** (RHEL 9.8) | **RHCOS 10** (RHEL 10.2) |
| `osImageStream` in install-config | Technology Preview (`OSStreams` gate) - rejected on a default install | GA, defaults to `rhel-10`; `rhel-9` still accepted |
| Default bootimage (`coreos print-stream-json`) | 9.8.20261026-0 | 10.2.20261026-0 |
| Bootimage on the mirror | `rhcos/4.22/4.22.21/` | `rhcos/5.0-el10/5.0.0/` |
| RHCOS 10 machine-os in the payload | 10.2.20261102-1 | 10.2.20261102-1 (same build) |
| Release manifests | 877 | 939 |
| Payload images | 192 | 198 |
| Channel | `stable-4.22` | `stable-5.0` (`fast-5.0` for updates from 4.22, see below) |
| Mirror tree for clients | `openshift-v4/` | `openshift-v5/` (also mirrored under `openshift-v4/`, same checksums) |
| Update in from | 4.21.6+, 4.22.x | 4.22.17 - 4.22.22, 5.0.0 |

## The change that matters most: the node OS

**OpenShift 5 moves new clusters to RHEL CoreOS 10.** Both installers carry
the same two bootimages - one RHEL 9.8, one RHEL 10.2 - and both payloads
carry both a `rhel-coreos` and a `rhel-coreos-10` image. What changed is the
default, and whether you are allowed to choose:

| | 4.22.22 installer | 5.0.1 installer |
|---|---|---|
| `osImageStream` omitted | no OS stream manifest, nodes on RHCOS 9 | `openshift/99_osimagestream.yaml` with `defaultStream: rhel-10` |
| `osImageStream: rhel-10` | **error**: field is protected by the `OSStreams` feature gate (TechPreviewNoUpgrade or CustomNoUpgrade only) | accepted |
| `osImageStream: rhel-9` | same error | accepted, `defaultStream: rhel-9` |
| `coreos print-stream-json` (default) | `rhel-9`: 9.8.20261026-0 | `rhel-10`: 10.2.20261026-0 |

All of the above was run, not inferred: `openshift-install create manifests`
on a `platform: none` install-config with each value, on both installers.

This corrects something this repo used to say. The 4.22 docs claimed a
4.22.22 node "spends the rest of its life on RHEL 10.2". It did not: 4.22
installed RHEL 9 everywhere unless you enabled a Technology Preview feature
set. `oc adm release info 4.22.22` prints `machine-os 10.2.20261102-1`, but
that line describes the RHEL 10 image the payload also ships, not the one the
nodes ran.

**Clusters updated from 4.22 stay on RHCOS 9.** Per Red Hat's announcement,
an in-place update to 5.0 does not move the nodes to RHEL 10; only new 5.0
clusters default to it. Mixing RHCOS 9 and 10 nodes in one cluster is
described as planned for a future release.

### Two 5.0.0 bootimages, and only one is RHEL 10

The mirror has two directories that look like "the 5.0 bootimage":

```
rhcos/5.0-el10/5.0.0/   RHEL 10.2 (10.2.20261026-0)   the rhel-10 bootimage
rhcos/5.0/5.0.0/        RHEL 9.8  (9.8.20261026-0)    byte-identical to rhcos/4.22/4.22.21/
```

All 42 files in `5.0/5.0.0/` have the same SHA-256 as `4.22/4.22.21/`. Taking
the bootimage from `5.0/` because it "looks like 5.0" gives a `rhel-10` cluster
a RHEL 9 bootimage. There is no `5.0.1` bootimage directory in either tree
(HTTP 404); 5.0.0 is the newest that exists.

## What changed in this lab

| Change in 5.x | What was done |
|---|---|
| New release, new channel | `ocp_version = "5.0.1"`, channel `stable-5.0` |
| Clients live under `openshift-v5/` | the mirror path takes the major version from `ocp_version`, so the same code fetches 4.x and 5.x |
| `osImageStream` is GA and defaults to `rhel-10` | new required variable `os_image_stream`, validated to `rhel-10`/`rhel-9`, written to install-config. Explicit, so a later default change cannot move a cluster |
| RHEL 10.2 bootimage | openstack (config-drive) and qemu (fw_cfg) images from `5.0-el10/5.0.0/` with their checksums |
| Bootimage must match the stream | new `terraform_data.bootimage_check`: asks the downloaded installer for the stream's bootimages and fails the apply, before the download, if `rhcos_image_sha256` is not one of them |
| Everything else in install-config | no change needed: every field this template uses is unchanged in the 5.0.1 schema |

OpenShift 5 also changes cloud installs - notably
`platform.azure.allowSharedKeyAccess` now defaults to `false` and needs a
`Storage Blob Data Contributor` role - but those are out of scope for this
KVM-only lab.

Checked: `terraform fmt` and `terraform validate` (Terraform 1.17.1), the
rendered install-config accepted by `openshift-install 5.0.1 create manifests`,
the bootimage check run against the 5.0.1 installer (it passes the RHEL 10.2
images and rejects the 4.22.21 RHEL 9.8 one for `rhel-10`), and a full install
plus a destroy-and-rebuild on libvirt.

## install-config.yaml, field by field

`openshift-install explain` on both installers, diffed. Only four things
changed in the parts these stacks use or might use:

| Field | 4.22.22 | 5.0.1 | Used here |
|---|---|---|---|
| `osImageStream` | `rhel-9`, `rhel-10` (gated, see above) | `rhel-9`, `rhel-10`, `centos-10`; GA | yes, `os_image_stream` |
| `platform.azure.allowSharedKeyAccess` | default `true` | default `false`, needs `Storage Blob Data Contributor` | no (cloud installs only) |
| `networking.networkObservability.installationPolicy` | - | `InstallAndEnable` / `NoAction`; **rejected unless the `NetworkObservabilityInstall` gate is on** (Technology Preview in 5.0.1 - tested) | no |
| `pki.signerCertificates` | - | key parameters for installer-generated CAs; gated by `ConfigurablePKI` | no |

`centos-10` is the OKD stream and is left out of the validation here.

Unchanged and still used here: `platform: none`, `publish`, `fips`,
`featureSet` (`Default`, `TechPreviewNoUpgrade`, `CustomNoUpgrade`),
`capabilities` (`baselineCapabilitySet` still tops out at `v4.18` plus
`vCurrent`).

## What is new in the payload

From `oc adm release info` and `oc adm release extract` on both releases.

**Images added in 5.0.1:** `agentic-skills`, `cluster-update-console-plugin`,
`driver-toolkit-10`, `haproxy-router-haproxy28`, `haproxy-router-haproxy32`,
`karpenter-operator`, `kube-vip`. **Removed:** `oc-mirror`.

**New cluster capabilities:** `ClusterAPI`, `CompatibilityRequirements`. None
were removed.

**Feature gates now on by default** (in the Default feature set for 5.x, not
in 4.22): `AdditionalStorageConfig`, `AWSClusterHostedDNSInstall`,
`AWSDualStackInstall`, `CRIOCredentialProviderConfig`, `EtcdBackendQuota`,
`ExternalOIDCWithUpstreamParity`, `IngressControllerMultipleHAProxyVersions`,
`IrreconcilableMachineConfig`, `MutatingAdmissionPolicy`,
`OLMLifecycleAndCompatibility`, `OSStreams`, `SELinuxMountGAReadiness`,
`VolumeGroupSnapshot`.

**Gates gone from the 5.x Default list:** `AzureClusterHostedDNSInstall`,
`ConsolePluginContentSecurityPolicy`, `RouteExternalCertificate`,
`UserNamespacesPodSecurityStandards`, `UserNamespacesSupport`. None of them
appears as *disabled* either - the gate itself is gone from the 5.x feature
gate files, which usually means the feature graduated and the switch was
retired. The payload alone cannot tell graduated from removed; the release
notes can.

New operator manifests worth knowing about: a Cluster API operator (with a
metal3 provider), a Karpenter operator and a CRD compatibility checker.

## Platform changes from Red Hat's announcement

Not measured here - taken from Red Hat's GA announcement and developer
article. GA vs Technology Preview is as stated there.

| Area | Change | Status |
|---|---|---|
| Lifecycle | Extended Life Cycle (ELC) replaces EUS: one ELC release a year, 5 years of support through an add-on, also covering ACS, Service Mesh, Pipelines and GitOps. 3-year major release cadence | announced |
| Update | 4.22 to 5.0 is an in-place minor-style update, no migration | GA |
| Security | Post-quantum readiness in platform images and TLS config; one enforced TLS configuration across core and layered products; network policies on platform operand namespaces | GA |
| Auth | Direct authentication to an external OIDC provider (Keycloak, Okta, Entra ID, GitLab) instead of the built-in OAuth server | GA |
| AI tooling | MCP server for OpenShift, MCP gateway via Connectivity Link | GA |
| AI tooling | Lightspeed autonomous troubleshooting, update agent | Technology Preview |
| AI tooling | Red Hat build of Agent Sandbox (agent workloads in Kata VMs) | Technology Preview |
| Virtualization | Incremental backup with QEMU change block tracking, memory-aware live migration with swap, "virtualization autopilot", node-centric management view | announced |
| Workloads | Dynamic resource allocation with partitionable devices and consumable capacity | announced, maturity not stated |
| Tooling | Migration toolkit for containers end of life (replaced by MTA 8.3); standalone Builds fold into OpenShift Pipelines after 1.10; console SDK moves to Helm 4 | announced |

## Updating an existing 4.22.22 cluster

The update graph (`api.openshift.com`, read 2026-11-12) has
`4.22.22 -> 5.0.1`, and from 4.22.17 onward. That edge is in **`fast-5.0`
only**: `stable-5.0` has no edge from 4.22 yet, just `5.0.0 -> 5.0.1`.

```bash
oc adm upgrade channel fast-5.0
oc adm upgrade --to=5.0.1
```

Expect the nodes to stay on RHCOS 9 afterwards (see above). These stacks do
not drive updates: changing `ocp_version` on an installed cluster replaces
the Ignition configs on libvirt and re-runs the installer on the clouds,
which is a reinstall, not an update. Update through the cluster.

## How this was measured

All on 2026-11-12, against the public mirror and update service. No pull
secret is needed for any of it.

```bash
# both installers, checksum-verified against the mirror's sha256sum.txt
openshift-install version
openshift-install coreos print-stream-json --stream rhel-9|rhel-10
openshift-install explain installconfig[.<path>]        # schema, diffed 4.22.22 vs 5.0.1
openshift-install create manifests --dir .              # osImageStream, networkObservability tests

# both payloads
oc adm release info quay.io/openshift-release-dev/ocp-release:<v>-x86_64
oc adm release extract --to <dir> quay.io/openshift-release-dev/ocp-release:<v>-x86_64
yq '.status.featureGates[].enabled[].name' <dir>/0000_50_cluster-config-api_featureGate-*-SelfManagedHA-Default.yaml

# channels and edges
curl -s -H 'Accept: application/json' \
  'https://api.openshift.com/api/upgrades_info/v1/graph?channel=fast-5.0&arch=amd64'
```

Not done: reading the 5.0 release notes on docs.redhat.com, which refuses
automated fetches, so the full deprecated/removed list and the 5.0 hardware
minimums come from there and are not reproduced here. The control plane
sizing in these stacks (4 vCPU, 16 GiB) is unchanged from 4.22.

## Sources

- [Red Hat OpenShift 5 announcement](https://www.redhat.com/en/blog/announcing-red-hat-openshift-5)
- [What's new in Red Hat OpenShift 5 for developers](https://developers.redhat.com/articles/2026/11/09/red-hat-openshift-5-for-developers)
- [OpenShift Container Platform 5.0 release notes](https://docs.redhat.com/en/documentation/openshift_container_platform/5.0/html/release_notes/ocp-5-0-release-notes)
- [Clients and bootimages on mirror.openshift.com](https://mirror.openshift.com/pub/openshift-v5/x86_64/)
