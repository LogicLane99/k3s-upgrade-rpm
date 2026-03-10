# K3s Airgapped Upgrade — End User Guide

**RPM-based cluster upgrade via System Upgrade Controller**
**Version target: configurable at build time (example: v1.33.3)**

---

## Overview

This guide covers building and using the `k3s-upgrade-v<VERSION>` RPM to upgrade a
fully airgapped multi-node k3s cluster. The upgrade uses the
[System Upgrade Controller (SUC)](https://github.com/rancher/system-upgrade-controller)
to handle rolling node upgrades in the correct order:

```
Servers first (one at a time)  →  Agents second (two at a time, with drain)
```

No internet access is required on the cluster. All manifests, scripts, and the k3s
airgap image tar are bundled in the RPM.

---

## Architecture: What's in the RPM

```
k3s-upgrade-v1.33.3-1.el9.noarch.rpm
│
├── /usr/lib/k3s-upgrade/
│   ├── apply-upgrade.sh                      ← Upgrade orchestrator (values baked in)
│   ├── images/
│   │   └── k3s-airgap-images-amd64.tar.zst  ← k3s runtime images for v1.33.3
│   └── manifests/
│       ├── system-upgrade-controller.yaml   ← SUC: CRD, RBAC, Deployment (images baked in)
│       └── upgrade-plan.yaml               ← Server + Agent Plans
│
└── /etc/k3s-upgrade/
    └── version.env                          ← Version metadata
```

### Two image types — both required

| Image | Type | Purpose |
|---|---|---|
| `k3s-airgap-images-amd64.tar.zst` | Tarball (not OCI) | k3s runtime images: coredns, traefik, local-path, metrics-server. Loaded by containerd at k3s startup. **Must be present on every node before upgrade.** |
| `rancher/k3s-upgrade:v1.33.3` | OCI container image | Run by SUC as a Kubernetes Job. Copies the k3s binary to the node and restarts the service. Must be in your Nexus registry. |
| `rancher/system-upgrade-controller:v0.14.1` | OCI container image | The SUC controller pod itself. Must be in Nexus. |
| `rancher/kubectl:v1.30.2` | OCI container image | Used by SUC's `prepare` Jobs to check Plan status. Must be in Nexus. |

---

## Multi-Node Upgrade Sequence

```
Cluster example: server1, server2 (control-plane) + agent1, agent2, agent3 (workers)

PHASE 1 — SERVER UPGRADE (concurrency: 1)
─────────────────────────────────────────────────────────────────────────
  server1:  SUC Job starts → cordon → copy binary + restart k3s → ✔ v1.33.3
                                           ↓ (concurrency 1: server2 waits)
  server2:  SUC Job starts → cordon → copy binary + restart k3s → ✔ v1.33.3

  [ALL SERVER NODES NOW ON v1.33.3]

PHASE 2 — AGENT UPGRADE (concurrency: 2, with drain)
─────────────────────────────────────────────────────────────────────────
  agent1 + agent2: Jobs start simultaneously
                   → prepare: checks server Plan is complete ✔
                   → cordon → drain → copy binary + restart k3s → uncordon → ✔
                                           ↓ (1 slot opens)
  agent3:  Job starts → prepare ✔ → cordon → drain → upgrade → uncordon → ✔

  [ALL NODES ON v1.33.3 — UPGRADE COMPLETE]
```

The `prepare:` block in the agent Plan is the sequencing mechanism. It runs a
container that polls SUC's API for the server Plan status and blocks agent Jobs
from starting until every server node has completed.

---

## Prerequisites

### Build machine (internet or Nexus access)

| Requirement | Package | Check |
|---|---|---|
| rpmbuild | `dnf install rpm-build` | `rpmbuild --version` |
| curl | `dnf install curl` | `curl --version` |
| skopeo (optional, for image mirroring) | `dnf install skopeo` | `skopeo --version` |

### Nexus — required images

Mirror these images to your Nexus container registry **before** building the RPM:

```
rancher/k3s-upgrade:v1.33.3
rancher/system-upgrade-controller:v0.14.1
rancher/kubectl:v1.30.2
```

Mirror command (run on internet-connected machine):
```bash
for IMG in \
    "rancher/k3s-upgrade:v1.33.3" \
    "rancher/system-upgrade-controller:v0.14.1" \
    "rancher/kubectl:v1.30.2"
do
    skopeo copy \
        "docker://docker.io/${IMG}" \
        "docker://nexus.internal:5000/${IMG}" \
        --dest-tls-verify=false
done
```

### k3s airgap image tar

Fetch from GitHub (or your Nexus binary store) on your build machine:
```bash
K3S_VERSION=1.33.3
curl -fSL \
    "https://github.com/k3s-io/k3s/releases/download/v${K3S_VERSION}%2Bk3s1/k3s-airgap-images-amd64.tar.zst" \
    -o "k3s-airgap-images-amd64.tar.zst"
```

Place it at `SOURCES/images/k3s-airgap-images-amd64.tar.zst` before running `build-rpm.sh`.

### Cluster nodes — SSH access

The RPM's `%post` script SSH-copies the airgap tar to all nodes. The k3s server
node must have SSH key access to all cluster nodes.

```bash
# Test from the k3s server node
ssh root@<agent-node-ip> "echo ssh-ok"
```

If SSH keys aren't set up:
```bash
# Generate and distribute key from server node
ssh-keygen -t ed25519 -f /root/.ssh/k3s-upgrade -N ""
for NODE_IP in 10.0.0.11 10.0.0.12 10.0.0.13; do
    ssh-copy-id -i /root/.ssh/k3s-upgrade.pub root@${NODE_IP}
done
```

---

## Step-by-Step Build and Deploy

### Step 1 — Prepare sources on your build machine

```
k3s-upgrade-rpm/
├── build-rpm.sh
├── stage-images.sh
├── SPECS/
│   └── k3s-upgrade.spec
└── SOURCES/
    ├── scripts/
    │   └── apply-upgrade.sh
    ├── manifests/
    │   ├── system-upgrade-controller.yaml
    │   └── upgrade-plan.yaml
    └── images/
        └── k3s-airgap-images-amd64.tar.zst   ← place here before building
```

### Step 2 — Build the RPM

```bash
# Basic build (uses defaults: registry=nexus.internal:5000, version=1.33.3)
K3S_VERSION=1.33.3 \
REGISTRY=nexus.internal:5000 \
./build-rpm.sh
```

With all options:
```bash
K3S_VERSION=1.33.3 \
REGISTRY=nexus.internal:5000 \
SUC_CONTROLLER_VERSION=0.14.1 \
SUC_KUBECTL_VERSION=1.30.2 \
AIRGAP_ARCH=amd64 \
NEXUS_RPM_REPO=https://nexus.internal/repository/rhel9-local \
NEXUS_USER=admin \
NEXUS_PASS=mypassword \
./build-rpm.sh
```

The RPM is produced at:
```
~/rpmbuild/RPMS/noarch/k3s-upgrade-v1.33.3-1.33.3-1.noarch.rpm
```

### Step 3 — Publish RPM to Nexus (or copy directly)

**Option A: Push to Nexus hosted RPM repository**
```bash
curl -u admin:PASSWORD \
    --upload-file ~/rpmbuild/RPMS/noarch/k3s-upgrade-v1.33.3-1.33.3-1.noarch.rpm \
    https://nexus.internal/repository/rhel9-local/k3s-upgrade-v1.33.3-1.33.3-1.noarch.rpm
```

**Option B: SCP directly to the k3s server node**
```bash
scp ~/rpmbuild/RPMS/noarch/k3s-upgrade-v1.33.3-1.33.3-1.noarch.rpm \
    root@k3s-server01:/tmp/
```

### Step 4 — Configure containerd mirror on all nodes (if not done already)

Each node needs `registries.yaml` so containerd can pull from Nexus:

```bash
# /etc/rancher/k3s/registries.yaml  (on every node)
mirrors:
  "nexus.internal:5000":
    endpoint:
      - "https://nexus.internal:5000"
  docker.io:
    endpoint:
      - "https://nexus.internal:5000"

configs:
  "nexus.internal:5000":
    tls:
      insecure_skip_verify: true   # remove if Nexus has a valid cert
```

Apply by restarting k3s (or it will pick up on upgrade restart):
```bash
systemctl restart k3s        # on server nodes
systemctl restart k3s-agent  # on agent nodes
```

### Step 5 — Install the RPM on the k3s server node

```bash
# From Nexus dnf repo (if repo is configured)
dnf install k3s-upgrade-v1.33.3

# OR from local file
dnf install /tmp/k3s-upgrade-v1.33.3-1.33.3-1.noarch.rpm

# With explicit SSH key (if needed)
SSH_KEY=/root/.ssh/k3s-upgrade \
    dnf install k3s-upgrade-v1.33.3

# With all SSH overrides
SSH_USER=ansible \
SSH_KEY=/root/.ssh/id_ed25519 \
SSH_PORT=2222 \
    dnf install /tmp/k3s-upgrade-v1.33.3-1.33.3-1.noarch.rpm
```

**What happens automatically (`%post`):**

```
1. Preflight checks
   ├─ Checks kubectl, SSH, KUBECONFIG
   ├─ Reports cluster topology (N servers, N agents)
   └─ Reports current vs target version

2. Stage airgap tar on ALL nodes (via SSH/SCP)
   ├─ Finds every node's InternalIP via kubectl
   ├─ SSH-copies k3s-airgap-images-amd64.tar.zst to each node
   └─ Skips if file already present (size-based check)
      Destination: /var/lib/rancher/k3s/agent/images/k3s-airgap-images-v1.33.3-amd64.tar.zst

3. Deploy System Upgrade Controller
   ├─ Applies CRD, Namespace, RBAC, ConfigMap, Deployment
   └─ Waits for controller pod to be Ready (3 min timeout)

4. Apply Upgrade Plans
   ├─ k3s-server-upgrade: targets control-plane nodes, concurrency=1, cordon
   └─ k3s-agent-upgrade: targets workers, concurrency=2, cordon+drain,
                          BLOCKED until all servers complete (prepare: block)

5. Watch upgrade progress
   ├─ Polls node versions every 20 seconds
   ├─ Reports active Jobs, failed pods
   └─ Exits when all nodes report v1.33.3
      (30 min timeout; upgrade continues in background if detached)
```

---

## Manual Subcommands

After installation, the upgrade script is available at:
`/usr/lib/k3s-upgrade/apply-upgrade.sh`

```bash
# Full upgrade flow (same as %post)
/usr/lib/k3s-upgrade/apply-upgrade.sh apply

# Stage airgap tar on all nodes only (SSH distribution)
/usr/lib/k3s-upgrade/apply-upgrade.sh stage-images

# Deploy/update SUC controller only
/usr/lib/k3s-upgrade/apply-upgrade.sh suc-only

# Apply Plans only (SUC must already be running)
/usr/lib/k3s-upgrade/apply-upgrade.sh plans-only

# Show current upgrade state
/usr/lib/k3s-upgrade/apply-upgrade.sh status

# Re-attach to live progress monitor
/usr/lib/k3s-upgrade/apply-upgrade.sh watch

# Abort: remove Plans (nodes already upgraded stay upgraded)
/usr/lib/k3s-upgrade/apply-upgrade.sh rollback
```

### Environment overrides

```bash
KUBECONFIG=/path/to/kubeconfig \
SSH_USER=ubuntu \
SSH_KEY=/root/.ssh/id_ed25519 \
SSH_PORT=22 \
UPGRADE_TIMEOUT=3600 \
    /usr/lib/k3s-upgrade/apply-upgrade.sh apply
```

---

## Monitoring the Upgrade

### Watch nodes live
```bash
watch kubectl get nodes -o wide
```

### Watch SUC Jobs
```bash
watch kubectl get jobs -n system-upgrade
```

### Watch Plans
```bash
kubectl get plans.upgrade.cattle.io -n system-upgrade -w
```

### Check SUC controller logs
```bash
kubectl logs -n system-upgrade \
    -l upgrade.cattle.io/controller=system-upgrade \
    --follow
```

### Check an upgrade Job's logs
```bash
# List jobs
kubectl get jobs -n system-upgrade

# Get logs for a specific job
kubectl logs -n system-upgrade \
    -l upgrade.cattle.io/plan=k3s-server-upgrade \
    --follow
```

---

## Troubleshooting

### Airgap tar staging failed for some nodes

```bash
# Manually copy to a specific node
SSH_KEY=/root/.ssh/id_ed25519 \
NODE_IPS="10.0.0.12" \
AIRGAP_TAR=/usr/lib/k3s-upgrade/images/k3s-airgap-images-amd64.tar.zst \
./stage-images.sh remote

# OR directly on the node itself
scp root@build-box:/path/to/k3s-airgap-images-amd64.tar.zst \
    /var/lib/rancher/k3s/agent/images/k3s-airgap-images-v1.33.3-amd64.tar.zst
```

### SUC controller pod not starting (ImagePullBackOff)

The SUC controller image isn't available in containerd. Check:
```bash
kubectl describe pod -n system-upgrade -l upgrade.cattle.io/controller=system-upgrade

# Verify registries.yaml is correct on the server node
cat /etc/rancher/k3s/registries.yaml

# Check containerd can see the image
crictl images | grep system-upgrade-controller
```

### Upgrade Job stuck or failing

```bash
# Describe the failing pod
kubectl get pods -n system-upgrade
kubectl describe pod -n system-upgrade <pod-name>
kubectl logs -n system-upgrade <pod-name>

# Common cause: k3s-airgap-images tar missing on that node
# Solution: stage it manually (see above)
```

### Plans applied but no Jobs created

SUC watches Plans but only creates Jobs when nodes don't have the target label.
Check:
```bash
kubectl get plans -n system-upgrade -o yaml

# Nodes may already be annotated as complete from a previous attempt
# Clear annotations to re-trigger:
kubectl annotate node <node-name> \
    plan.upgrade.cattle.io/k3s-server-upgrade- \
    --overwrite
```

### Rolling back a partial upgrade

```bash
# Stop further upgrades (doesn't revert already-upgraded nodes)
/usr/lib/k3s-upgrade/apply-upgrade.sh rollback

# To downgrade already-upgraded nodes, install the previous version RPM:
dnf install k3s-upgrade-v1.32.5
# This will apply Plans pointing to v1.32.5
```

---

## Upgrading to a different version later

Each version has its own RPM with a unique name. They coexist in Nexus.

```bash
# Upgrade to next version — just install the new RPM
dnf install k3s-upgrade-v1.34.0

# The %pre scriptlet warns about existing Plans
# The %post scriptlet replaces them with v1.34.0 Plans automatically
```

Build the next version:
```bash
K3S_VERSION=1.34.0 REGISTRY=nexus.internal:5000 ./build-rpm.sh
```

---

## File Reference

| File | Location | Description |
|---|---|---|
| `apply-upgrade.sh` | `/usr/lib/k3s-upgrade/apply-upgrade.sh` | Main orchestration script |
| `system-upgrade-controller.yaml` | `/usr/lib/k3s-upgrade/manifests/` | SUC manifests (images baked in) |
| `upgrade-plan.yaml` | `/usr/lib/k3s-upgrade/manifests/` | Server + Agent Plans |
| `k3s-airgap-images-amd64.tar.zst` | `/usr/lib/k3s-upgrade/images/` | k3s runtime image bundle |
| `version.env` | `/etc/k3s-upgrade/version.env` | Metadata (version, image refs, build date) |

---

## Quick Reference Card

```bash
# BUILD  ──────────────────────────────────────────────────────────────────────
# Place airgap tar at: SOURCES/images/k3s-airgap-images-amd64.tar.zst
K3S_VERSION=1.33.3 REGISTRY=nexus.internal:5000 ./build-rpm.sh

# PUBLISH ─────────────────────────────────────────────────────────────────────
curl -u admin:PASS --upload-file k3s-upgrade-v1.33.3-*.noarch.rpm \
     https://nexus.internal/repository/rhel9-local/

# INSTALL (triggers full upgrade automatically) ────────────────────────────────
SSH_KEY=/root/.ssh/id_ed25519 dnf install k3s-upgrade-v1.33.3

# MONITOR ─────────────────────────────────────────────────────────────────────
/usr/lib/k3s-upgrade/apply-upgrade.sh status
watch kubectl get nodes -o wide
kubectl get jobs -n system-upgrade -w

# MANUAL SUBCOMMANDS ──────────────────────────────────────────────────────────
/usr/lib/k3s-upgrade/apply-upgrade.sh stage-images  # re-distribute airgap tar
/usr/lib/k3s-upgrade/apply-upgrade.sh watch         # re-attach to progress
/usr/lib/k3s-upgrade/apply-upgrade.sh rollback      # abort upgrade
```
