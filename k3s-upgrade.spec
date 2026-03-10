# =============================================================================
# k3s-upgrade.spec
#
# Produces: k3s-upgrade-v1.33.3-1.el9.noarch.rpm
#
# The airgap image tar is NOT bundled here. Instead, apply-upgrade.sh
# SSH-connects to every cluster node and runs:
#   dnf install -y --nogpgcheck --disablerepo='*' <K3S_AIRGAP_RPM_URL>
# where K3S_AIRGAP_RPM_URL is baked in at build time.
#
# Build with build-rpm.sh, or directly:
#   rpmbuild -ba k3s-upgrade.spec \
#       --define "k3s_version           1.33.3" \
#       --define "k3s_airgap_rpm_url    https://nexus.company.com/repository/k3s/k3s/v1.33.3/k3s-airgap-images-1.33.3.rpm" \
#       --define "k3s_upgrade_image     nexus.company.com:5000/rancher/k3s-upgrade:v1.33.3-k3s1" \
#       --define "suc_controller_image  nexus.company.com:5000/rancher/system-upgrade-controller:v0.14.1" \
#       --define "suc_kubectl_image     nexus.company.com:5000/rancher/kubectl:v1.33.3"
# =============================================================================

# ── Build-time defines (all settable via --define) ────────────────────────────
%{!?k3s_version:          %global k3s_version          1.33.3}
%{!?k3s_airgap_rpm_url:   %global k3s_airgap_rpm_url   https://nexus.company.com/repository/k3s/k3s/v%{k3s_version}/k3s-airgap-images-%{k3s_version}.rpm}
%{!?k3s_upgrade_image:    %global k3s_upgrade_image    nexus.company.com:5000/rancher/k3s-upgrade:v%{k3s_version}-k3s1}
%{!?suc_controller_image: %global suc_controller_image nexus.company.com:5000/rancher/system-upgrade-controller:v0.14.1}
%{!?suc_kubectl_image:    %global suc_kubectl_image    nexus.company.com:5000/rancher/kubectl:v%{k3s_version}}

# ── Package metadata ──────────────────────────────────────────────────────────
Name:           k3s-upgrade-v%{k3s_version}
Version:        %{k3s_version}
Release:        1%{?dist}
Summary:        Airgapped k3s cluster upgrade to v%{k3s_version} via System Upgrade Controller
License:        Apache-2.0
BuildArch:      noarch
URL:            https://github.com/k3s-io/k3s

%description
Upgrades a k3s cluster to v%{k3s_version} using the System Upgrade Controller (SUC).
Designed for FULLY AIRGAPPED RHEL/Rocky/Alma environments.

On dnf install, this RPM automatically:
  1. SSH-connects to every cluster node and runs:
       dnf install -y --nogpgcheck --disablerepo='*' <airgap-rpm-url>
     to stage the k3s v%{k3s_version} airgap images on each node
  2. Deploys the System Upgrade Controller into the cluster
  3. Applies server-first upgrade Plans (concurrency: 1 server, 2 agents)
  4. Watches until all nodes report v%{k3s_version}

Baked-in values (set at build time, cannot change after build):
  Airgap RPM URL  : %{k3s_airgap_rpm_url}
  k3s upgrade img : %{k3s_upgrade_image}
  SUC controller  : %{suc_controller_image}
  SUC kubectl     : %{suc_kubectl_image}

SSH configuration (set before dnf install or before re-running apply-upgrade.sh):
  SSH_USER    (default: root)
  SSH_KEY     (default: ssh-agent)
  SSH_PORT    (default: 22)
  NEXUS_USER  (optional: Nexus username if airgap RPM URL requires auth)
  NEXUS_PASS  (optional: Nexus password if airgap RPM URL requires auth)

Re-run manually:
  /usr/lib/k3s-upgrade/apply-upgrade.sh [apply|stage-images|status|rollback|watch]

# ── Prep ──────────────────────────────────────────────────────────────────────
%prep
# No tarball — all content is generated in %install

# ── Build ─────────────────────────────────────────────────────────────────────
%build
# Nothing to compile

# ── Install (populate buildroot) ──────────────────────────────────────────────
%install
rm -rf %{buildroot}

install -d %{buildroot}/usr/lib/k3s-upgrade/manifests
install -d %{buildroot}/usr/lib/k3s-upgrade/bin
install -d %{buildroot}/etc/k3s-upgrade

# ── Render apply-upgrade.sh: substitute all build-time placeholders ──────────
SCRIPT_OUT=%{_builddir}/apply-upgrade.sh

sed \
    -e 's|__K3S_VERSION__|%{k3s_version}|g' \
    -e 's|__K3S_UPGRADE_IMAGE__|%{k3s_upgrade_image}|g' \
    -e 's|__SUC_CONTROLLER_IMAGE__|%{suc_controller_image}|g' \
    -e 's|__SUC_KUBECTL_IMAGE__|%{suc_kubectl_image}|g' \
    -e 's|__K3S_AIRGAP_RPM_URL__|%{k3s_airgap_rpm_url}|g' \
    %{_sourcedir}/scripts/apply-upgrade.sh > "${SCRIPT_OUT}"

install -m 0755 "${SCRIPT_OUT}" \
    %{buildroot}/usr/lib/k3s-upgrade/apply-upgrade.sh

# ── Render system-upgrade-controller.yaml: bake in OCI image refs ────────────
SUC_OUT=%{_builddir}/system-upgrade-controller.yaml

sed \
    -e 's|SUC_CONTROLLER_IMAGE_PLACEHOLDER|%{suc_controller_image}|g' \
    -e 's|SUC_KUBECTL_IMAGE_PLACEHOLDER|%{suc_kubectl_image}|g' \
    %{_sourcedir}/manifests/system-upgrade-controller.yaml > "${SUC_OUT}"

install -m 0644 "${SUC_OUT}" \
    %{buildroot}/usr/lib/k3s-upgrade/manifests/system-upgrade-controller.yaml

# ── upgrade-plan.yaml: K3S_VERSION_PLACEHOLDER and K3S_UPGRADE_IMAGE_PLACEHOLDER
#    are resolved at runtime by apply-upgrade.sh (not at build time)
install -m 0644 %{_sourcedir}/manifests/upgrade-plan.yaml \
    %{buildroot}/usr/lib/k3s-upgrade/manifests/upgrade-plan.yaml

# ── Version metadata ──────────────────────────────────────────────────────────
cat > %{buildroot}/etc/k3s-upgrade/version.env << EOF
K3S_TARGET_VERSION=%{k3s_version}
K3S_AIRGAP_RPM_URL=%{k3s_airgap_rpm_url}
K3S_UPGRADE_IMAGE=%{k3s_upgrade_image}
SUC_CONTROLLER_IMAGE=%{suc_controller_image}
SUC_KUBECTL_IMAGE=%{suc_kubectl_image}
RPM_BUILD_DATE=$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)
EOF

# ── Pre-install scriptlet ─────────────────────────────────────────────────────
%pre
if command -v kubectl >/dev/null 2>&1; then
    KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
    export KUBECONFIG
    EXISTING=$(kubectl get plans.upgrade.cattle.io -n system-upgrade \
        --no-headers 2>/dev/null | awk '{print $1}' | tr '\n' ' ' || true)
    if [ -n "${EXISTING}" ]; then
        echo "[k3s-upgrade] INFO: Existing Plans found: ${EXISTING}"
        echo "[k3s-upgrade] INFO: These will be replaced by v%{k3s_version} Plans during %post."
    fi
fi
exit 0

# ── Post-install scriptlet ────────────────────────────────────────────────────
%post
set -e

echo ""
echo "================================================================"
echo " k3s-upgrade v%{k3s_version} — Starting cluster upgrade"
echo "================================================================"
echo ""
echo " Airgap RPM URL : %{k3s_airgap_rpm_url}"
echo " k3s upgrade img: %{k3s_upgrade_image}"
echo " SUC controller : %{suc_controller_image}"
echo ""
echo " SSH_USER  = ${SSH_USER:-root}"
echo " SSH_KEY   = ${SSH_KEY:-(agent default)}"
echo " SSH_PORT  = ${SSH_PORT:-22}"
echo " NEXUS_USER= ${NEXUS_USER:-(not set — URL assumed public or pre-authed)}"
echo ""

/usr/lib/k3s-upgrade/apply-upgrade.sh apply

echo ""
echo "================================================================"
echo " Post-install complete."
echo " Status  : /usr/lib/k3s-upgrade/apply-upgrade.sh status"
echo " Re-run  : /usr/lib/k3s-upgrade/apply-upgrade.sh apply"
echo " Rollback: /usr/lib/k3s-upgrade/apply-upgrade.sh rollback"
echo "================================================================"

# ── Pre-uninstall scriptlet ───────────────────────────────────────────────────
%preun
if [ "$1" -eq 0 ]; then
    echo "[k3s-upgrade] Removing upgrade Plans on uninstall..."
    if command -v kubectl >/dev/null 2>&1; then
        KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
        export KUBECONFIG
        kubectl delete plans.upgrade.cattle.io \
            k3s-server-upgrade k3s-agent-upgrade \
            -n system-upgrade --ignore-not-found 2>/dev/null || true
        echo "[k3s-upgrade] Plans removed."
    fi
fi
exit 0

# ── Files ─────────────────────────────────────────────────────────────────────
%files
%defattr(-,root,root,-)
/usr/lib/k3s-upgrade/
%config(noreplace) /etc/k3s-upgrade/version.env

# ── Changelog ────────────────────────────────────────────────────────────────
%changelog
* %(date "+%a %b %d %Y") Platform Engineering <platform@company.com> - %{k3s_version}-1
- Airgapped k3s upgrade RPM for v%{k3s_version}
- Airgap images installed per-node via: dnf install <nexus-rpm-url> over SSH
- URL: %{k3s_airgap_rpm_url}
- OCI images: %{k3s_upgrade_image}, %{suc_controller_image}, %{suc_kubectl_image}
