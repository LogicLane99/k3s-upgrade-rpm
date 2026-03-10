#!/usr/bin/env bash
# =============================================================================
# build-rpm.sh
#
# Builds the k3s-upgrade RPM. The RPM bundles all manifests and scripts;
# the k3s airgap image tar is NOT bundled — instead, nodes fetch it at
# install time by running:
#   dnf install -y --nogpgcheck --disablerepo='*' <K3S_AIRGAP_IMAGE_URL>
# over SSH, directly from your Nexus raw/RPM repository.
#
# Usage:
#   ./build-rpm.sh
#
#   K3S_VERSION=1.33.3 \
#   K3S_AIRGAP_IMAGE_URL=https://nexus.company.com/repository/k3s/k3s/v1.33.3/k3s-airgap-images-1.33.3.rpm \
#   K3S_UPGRADE_IMAGE=nexus.company.com:5000/rancher/k3s-upgrade:v1.33.3-k3s1 \
#   SUC_KUBECTL_IMAGE=nexus.company.com:5000/rancher/kubectl:v1.33.3 \
#   ./build-rpm.sh
#
# Required tools: rpmbuild  (dnf install rpm-build)
# =============================================================================
set -euo pipefail

# ── Configuration — override all via environment variables ────────────────────

K3S_VERSION="${K3S_VERSION:-1.33.3}"

# Full URL to the k3s airgap images RPM on Nexus.
# This URL is baked into apply-upgrade.sh and used at cluster install time.
K3S_AIRGAP_IMAGE_URL="${K3S_AIRGAP_IMAGE_URL:-https://nexus.company.com/repository/k3s/k3s/v${K3S_VERSION}/k3s-airgap-images-${K3S_VERSION}.rpm}"

# OCI image for the k3s-upgrade Job (used by SUC to do the binary swap on each node)
K3S_UPGRADE_IMAGE="${K3S_UPGRADE_IMAGE:-nexus.company.com:5000/rancher/k3s-upgrade:v${K3S_VERSION}-k3s1}"

# OCI image for the SUC controller Deployment
SUC_CONTROLLER_IMAGE="${SUC_CONTROLLER_IMAGE:-nexus.company.com:5000/rancher/system-upgrade-controller:v0.14.1}"

# OCI image for the SUC prepare/kubectl Jobs
SUC_KUBECTL_IMAGE="${SUC_KUBECTL_IMAGE:-nexus.company.com:5000/rancher/kubectl:v${K3S_VERSION}}"

# ── Optional: auto-upload RPM to Nexus after build ───────────────────────────
NEXUS_RPM_REPO="${NEXUS_RPM_REPO:-}"     # e.g. https://nexus.company.com/repository/rhel9-local
NEXUS_USER="${NEXUS_USER:-admin}"
NEXUS_PASS="${NEXUS_PASS:-}"

# ── Internal ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPMBUILD_DIR="${HOME}/rpmbuild"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'
info()   { echo -e "${CYAN}[build-rpm]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[build-rpm] ✔${RESET} $*"; }
warn()   { echo -e "${YELLOW}[build-rpm] ⚠${RESET} $*"; }
die()    { echo -e "${RED}[build-rpm] ✖${RESET} $*" >&2; exit 1; }
banner() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}\n"; }

# ── Preflight ─────────────────────────────────────────────────────────────────
preflight() {
    banner "Preflight"
    command -v rpmbuild &>/dev/null || die "rpmbuild not found — install: dnf install rpm-build"

    [[ -f "${SCRIPT_DIR}/SPECS/k3s-upgrade.spec" ]]                               || die "Missing: SPECS/k3s-upgrade.spec"
    [[ -f "${SCRIPT_DIR}/SOURCES/scripts/apply-upgrade.sh" ]]                     || die "Missing: SOURCES/scripts/apply-upgrade.sh"
    [[ -f "${SCRIPT_DIR}/SOURCES/manifests/upgrade-plan.yaml" ]]                  || die "Missing: SOURCES/manifests/upgrade-plan.yaml"
    [[ -f "${SCRIPT_DIR}/SOURCES/manifests/system-upgrade-controller.yaml" ]]     || die "Missing: SOURCES/manifests/system-upgrade-controller.yaml"

    info "Build configuration:"
    info "  k3s version      : v${K3S_VERSION}"
    info "  Airgap RPM URL   : ${K3S_AIRGAP_IMAGE_URL}"
    info "  k3s upgrade image: ${K3S_UPGRADE_IMAGE}"
    info "  SUC ctrl image   : ${SUC_CONTROLLER_IMAGE}"
    info "  SUC kubectl image: ${SUC_KUBECTL_IMAGE}"
    echo ""
    ok "Preflight passed"
}

# ── Set up rpmbuild directory tree ────────────────────────────────────────────
setup_rpmbuild() {
    banner "Setting Up rpmbuild Tree"

    mkdir -p "${RPMBUILD_DIR}/BUILD"
    mkdir -p "${RPMBUILD_DIR}/RPMS"
    mkdir -p "${RPMBUILD_DIR}/SRPMS"
    mkdir -p "${RPMBUILD_DIR}/SPECS"
    mkdir -p "${RPMBUILD_DIR}/SOURCES/scripts"
    mkdir -p "${RPMBUILD_DIR}/SOURCES/manifests"

    echo "%_topdir ${RPMBUILD_DIR}" > ~/.rpmmacros

    cp "${SCRIPT_DIR}/SOURCES/scripts/apply-upgrade.sh"                "${RPMBUILD_DIR}/SOURCES/scripts/"
    cp "${SCRIPT_DIR}/SOURCES/manifests/upgrade-plan.yaml"             "${RPMBUILD_DIR}/SOURCES/manifests/"
    cp "${SCRIPT_DIR}/SOURCES/manifests/system-upgrade-controller.yaml" "${RPMBUILD_DIR}/SOURCES/manifests/"
    cp "${SCRIPT_DIR}/SPECS/k3s-upgrade.spec"                          "${RPMBUILD_DIR}/SPECS/"

    ok "rpmbuild tree ready: ${RPMBUILD_DIR}"
}

# ── Build the RPM ─────────────────────────────────────────────────────────────
build_rpm() {
    banner "Building RPM"

    rpmbuild -ba \
        --define "k3s_version           ${K3S_VERSION}" \
        --define "k3s_airgap_rpm_url    ${K3S_AIRGAP_IMAGE_URL}" \
        --define "k3s_upgrade_image     ${K3S_UPGRADE_IMAGE}" \
        --define "suc_controller_image  ${SUC_CONTROLLER_IMAGE}" \
        --define "suc_kubectl_image     ${SUC_KUBECTL_IMAGE}" \
        "${RPMBUILD_DIR}/SPECS/k3s-upgrade.spec"
}

# ── Report and optionally upload ──────────────────────────────────────────────
report() {
    local RPM_FILE
    RPM_FILE=$(find "${RPMBUILD_DIR}/RPMS" -name "k3s-upgrade-v${K3S_VERSION}*.rpm" | head -1)
    [[ -n "${RPM_FILE}" ]] || die "RPM not found after build"

    echo ""
    ok "══════════════════════════════════════════════════════════════"
    ok " RPM: ${RPM_FILE}"
    ok " Size: $(du -sh "${RPM_FILE}" | cut -f1)"
    ok "══════════════════════════════════════════════════════════════"

    echo ""
    echo -e "${BOLD}Contents:${RESET}"
    rpm -qlp "${RPM_FILE}"

    echo ""
    echo -e "${BOLD}Baked-in values (verify these are correct):${RESET}"
    rpm -qp --queryformat \
        "  Name    : %{NAME}\n  Version : %{VERSION}\n  Summary : %{SUMMARY}\n" \
        "${RPM_FILE}"

    # Optional upload to Nexus RPM repo
    if [[ -n "${NEXUS_RPM_REPO}" && -n "${NEXUS_PASS}" ]]; then
        banner "Uploading to Nexus"
        local RPM_NAME; RPM_NAME=$(basename "${RPM_FILE}")
        info "Uploading to ${NEXUS_RPM_REPO}/${RPM_NAME}"
        curl -fSL \
            --user "${NEXUS_USER}:${NEXUS_PASS}" \
            --upload-file "${RPM_FILE}" \
            "${NEXUS_RPM_REPO}/${RPM_NAME}"
        ok "Uploaded"
    fi

    echo ""
    echo -e "${BOLD}Next steps:${RESET}"
    echo ""
    echo "  1. Push to Nexus RPM repo:"
    echo "       curl -u admin:PASS --upload-file ${RPM_FILE} \\"
    echo "            ${NEXUS_RPM_REPO:-https://nexus.company.com/repository/rhel9-local}/$(basename "${RPM_FILE}")"
    echo ""
    echo "  2. Ensure these OCI images are in your registry:"
    echo "       ${K3S_UPGRADE_IMAGE}"
    echo "       ${SUC_CONTROLLER_IMAGE}"
    echo "       ${SUC_KUBECTL_IMAGE}"
    echo ""
    echo "  3. Ensure the airgap RPM is accessible at:"
    echo "       ${K3S_AIRGAP_IMAGE_URL}"
    echo ""
    echo "  4. On the k3s server node (as root):"
    echo "       dnf install k3s-upgrade-v${K3S_VERSION}"
    echo ""
    echo "     Or with SSH key + Nexus auth:"
    echo "       SSH_KEY=/root/.ssh/id_ed25519 \\"
    echo "       NEXUS_USER=admin NEXUS_PASS=secret \\"
    echo "       dnf install k3s-upgrade-v${K3S_VERSION}"
    echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
preflight
setup_rpmbuild
build_rpm
report
