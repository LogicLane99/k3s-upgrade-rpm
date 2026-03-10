#!/usr/bin/env bash
# =============================================================================
# /usr/lib/k3s-upgrade/apply-upgrade.sh
#
# Installed by: k3s-upgrade-v<VERSION>-<RELEASE>.noarch.rpm
# Called automatically on: dnf install k3s-upgrade-v<VERSION>
# Re-run manually:         /usr/lib/k3s-upgrade/apply-upgrade.sh [SUBCOMMAND]
#
# Subcommands:
#   apply        Full flow: install airgap RPM on all nodes → deploy SUC → apply Plans → watch
#   stage-images Install k3s airgap RPM on all nodes only (via SSH + dnf)
#   suc-only     Deploy / update SUC controller only
#   plans-only   Apply upgrade Plans only (assumes SUC already running)
#   status       Show nodes, Plans, Jobs, per-node airgap RPM state
#   rollback     Delete Plans (halts further node upgrades)
#   watch        Re-attach to upgrade progress monitor
# =============================================================================
set -euo pipefail

# ── Values baked in at RPM build time ────────────────────────────────────────
K3S_TARGET_VERSION="__K3S_VERSION__"
K3S_UPGRADE_IMAGE="__K3S_UPGRADE_IMAGE__"
SUC_CONTROLLER_IMAGE="__SUC_CONTROLLER_IMAGE__"
SUC_KUBECTL_IMAGE="__SUC_KUBECTL_IMAGE__"

# Full URL of the k3s airgap images RPM on Nexus.
# Each cluster node will dnf-install this URL directly (via SSH).
# Example: https://nexus.company.com/repository/k3s/k3s/v1.33.3/k3s-airgap-images-1.33.3.rpm
K3S_AIRGAP_RPM_URL="__K3S_AIRGAP_RPM_URL__"

# ── Paths ─────────────────────────────────────────────────────────────────────
MANIFEST_DIR="/usr/lib/k3s-upgrade/manifests"

# ── SSH options (override via env before calling this script) ─────────────────
SSH_USER="${SSH_USER:-root}"
SSH_KEY="${SSH_KEY:-}"          # e.g. /root/.ssh/id_ed25519  (empty = use ssh-agent)
SSH_PORT="${SSH_PORT:-22}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"
[[ -n "${SSH_KEY}" ]] && SSH_OPTS="${SSH_OPTS} -i ${SSH_KEY}"

# ── Nexus credentials (injected into dnf URL if set) ─────────────────────────
# Use these if your Nexus repo requires HTTP basic auth.
# Credentials are embedded in the URL passed to dnf — NOT stored in a repo file.
NEXUS_USER="${NEXUS_USER:-}"
NEXUS_PASS="${NEXUS_PASS:-}"

# ── Upgrade watch settings ────────────────────────────────────────────────────
UPGRADE_TIMEOUT="${UPGRADE_TIMEOUT:-1800}"   # seconds; default 30 min
UPGRADE_POLL="${UPGRADE_POLL:-20}"           # seconds between polls

LOG_PREFIX="[k3s-upgrade]"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}${LOG_PREFIX}${RESET}  $*"; }
ok()    { echo -e "${GREEN}${LOG_PREFIX} ✔${RESET} $*"; }
warn()  { echo -e "${YELLOW}${LOG_PREFIX} ⚠${RESET} $*"; }
die()   { echo -e "${RED}${LOG_PREFIX} ✖${RESET} $*" >&2; exit 1; }
banner(){
    echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${CYAN}  $*${RESET}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}\n"
}

# ── Build the dnf install URL (with optional embedded credentials) ─────────────
# Embeds credentials into the URL so nodes don't need dnf repo config.
# Result: https://user:pass@nexus.company.com/repository/.../rpm  OR plain URL.
build_install_url() {
    if [[ -n "${NEXUS_USER}" && -n "${NEXUS_PASS}" ]]; then
        # Insert user:pass@ after the scheme  (https://  →  https://user:pass@)
        echo "${K3S_AIRGAP_RPM_URL}" | sed "s|https://|https://${NEXUS_USER}:${NEXUS_PASS}@|"
    else
        echo "${K3S_AIRGAP_RPM_URL}"
    fi
}

# ── Preflight ─────────────────────────────────────────────────────────────────
preflight() {
    banner "Preflight Checks"

    [[ $EUID -eq 0 ]] || die "Must run as root"

    command -v kubectl &>/dev/null || die "kubectl not found in PATH"
    command -v ssh     &>/dev/null || die "ssh not found in PATH"
    command -v curl    &>/dev/null || die "curl not found in PATH"

    # Resolve kubeconfig
    if [[ -z "${KUBECONFIG:-}" ]]; then
        if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
            export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        else
            die "KUBECONFIG not set and /etc/rancher/k3s/k3s.yaml not found"
        fi
    fi

    kubectl cluster-info &>/dev/null \
        || die "Cannot reach cluster via kubectl (KUBECONFIG=${KUBECONFIG})"

    local CURRENT_VERSION NODE_COUNT SERVER_COUNT AGENT_COUNT
    CURRENT_VERSION=$(kubectl get nodes \
        -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null || echo "unknown")
    NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    SERVER_COUNT=$(kubectl get nodes -l node-role.kubernetes.io/control-plane=true \
        --no-headers 2>/dev/null | wc -l || echo "?")
    AGENT_COUNT=$(( NODE_COUNT - SERVER_COUNT ))

    info "Cluster:"
    info "  Nodes          : ${NODE_COUNT}  (${SERVER_COUNT} server, ${AGENT_COUNT} agent)"
    info "  Current version: ${CURRENT_VERSION}"
    info "  Target version : v${K3S_TARGET_VERSION}"
    echo ""
    info "Images:"
    info "  Airgap RPM URL : ${K3S_AIRGAP_RPM_URL}"
    info "  k3s upgrade    : ${K3S_UPGRADE_IMAGE}"
    info "  SUC controller : ${SUC_CONTROLLER_IMAGE}"
    info "  SUC kubectl    : ${SUC_KUBECTL_IMAGE}"
    echo ""
    info "SSH:"
    info "  User: ${SSH_USER}  Port: ${SSH_PORT}  Key: ${SSH_KEY:-<agent default>}"
    echo ""

    # Validate airgap RPM URL reachability from this (server) node
    if [[ -n "${K3S_AIRGAP_RPM_URL}" ]]; then
        local HTTP_CODE
        HTTP_CODE=$(curl -sSo /dev/null -w "%{http_code}" \
            ${NEXUS_USER:+--user "${NEXUS_USER}:${NEXUS_PASS}"} \
            --max-time 10 -I "${K3S_AIRGAP_RPM_URL}" 2>/dev/null || echo "000")
        if [[ "${HTTP_CODE}" == "200" ]]; then
            ok "Airgap RPM URL reachable from this node (HTTP ${HTTP_CODE})"
        else
            warn "Airgap RPM URL check returned HTTP ${HTTP_CODE}"
            warn "URL: ${K3S_AIRGAP_RPM_URL}"
            warn "Nodes must reach this URL. Set NEXUS_USER/NEXUS_PASS if auth is required."
        fi
    fi

    ok "Preflight passed"
}

# ── Collect node names and IPs ────────────────────────────────────────────────
get_node_ips() {
    kubectl get nodes \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' \
        2>/dev/null
}

# ── SSH connectivity check ────────────────────────────────────────────────────
check_ssh() {
    local ip=$1
    ssh ${SSH_OPTS} -p "${SSH_PORT}" "${SSH_USER}@${ip}" "echo ssh-ok" &>/dev/null
}

# ── Check if the airgap RPM is already installed on a node ───────────────────
airgap_rpm_installed() {
    local ip=$1
    # grep rpm database for any k3s-airgap-images package
    ssh ${SSH_OPTS} -p "${SSH_PORT}" "${SSH_USER}@${ip}" \
        "rpm -qa 2>/dev/null | grep -qi 'k3s-airgap-images'" 2>/dev/null
}

# ── Install airgap RPM on all nodes via SSH + dnf ─────────────────────────────
install_airgap_rpm() {
    banner "Installing k3s Airgap Image RPM on All Nodes"

    if [[ -z "${K3S_AIRGAP_RPM_URL}" ]]; then
        warn "K3S_AIRGAP_RPM_URL is not set — skipping airgap RPM install"
        warn "Nodes must already have k3s v${K3S_TARGET_VERSION} airgap images loaded"
        return 0
    fi

    local INSTALL_URL
    INSTALL_URL=$(build_install_url)

    # The logged URL hides the password
    local LOG_URL="${K3S_AIRGAP_RPM_URL}"
    [[ -n "${NEXUS_USER}" ]] && LOG_URL=$(echo "${LOG_URL}" | sed "s|https://|https://${NEXUS_USER}:***@|")

    info "Airgap RPM  : ${LOG_URL}"
    info "dnf command : dnf install -y --nogpgcheck --disablerepo='*' '<url>'"
    echo ""

    # --nogpgcheck  : airgap RPMs from Nexus typically won't have GPG keys configured
    # --disablerepo : prevent dnf from trying to contact any configured repo during install
    local DNF_CMD="dnf install -y --nogpgcheck --disablerepo='*' '${INSTALL_URL}'"

    local -a FAILED_NODES=() SUCCESS_NODES=() SKIPPED_NODES=()

    while IFS=$'\t' read -r NODE_NAME NODE_IP; do
        [[ -z "${NODE_IP}" ]] && {
            warn "  [${NODE_NAME}] No InternalIP found — skipping"
            FAILED_NODES+=("${NODE_NAME}")
            continue
        }

        info "  ── [${NODE_NAME}]  ${NODE_IP}"

        # 1. SSH reachable?
        if ! check_ssh "${NODE_IP}"; then
            warn "  [${NODE_NAME}] SSH FAILED  (${SSH_USER}@${NODE_IP}:${SSH_PORT})"
            warn "  [${NODE_NAME}] Key: ${SSH_KEY:-<agent default>}"
            warn "  [${NODE_NAME}] Install manually on this node:"
            warn "  [${NODE_NAME}]   ${DNF_CMD}"
            FAILED_NODES+=("${NODE_NAME}/${NODE_IP}")
            echo ""
            continue
        fi

        # 2. Already installed?
        if airgap_rpm_installed "${NODE_IP}"; then
            local INSTALLED_PKG
            INSTALLED_PKG=$(ssh ${SSH_OPTS} -p "${SSH_PORT}" "${SSH_USER}@${NODE_IP}" \
                "rpm -qa | grep -i 'k3s-airgap-images' | head -1" 2>/dev/null || echo "unknown")
            ok "  [${NODE_NAME}] Already installed: ${INSTALLED_PKG} — skipping"
            SKIPPED_NODES+=("${NODE_NAME}")
            echo ""
            continue
        fi

        # 3. Run dnf install on the remote node, streaming output with node prefix
        info "  [${NODE_NAME}] Running dnf install..."
        local DNF_EXIT=0
        ssh ${SSH_OPTS} -p "${SSH_PORT}" "${SSH_USER}@${NODE_IP}" \
            "set -e; ${DNF_CMD}" 2>&1 \
            | sed "s/^/    [${NODE_NAME}] /" \
            || DNF_EXIT=$?

        if [[ ${DNF_EXIT} -eq 0 ]]; then
            ok "  [${NODE_NAME}] ✔ Airgap RPM installed successfully"
            SUCCESS_NODES+=("${NODE_NAME}")
        else
            warn "  [${NODE_NAME}] ✖ dnf install failed (exit ${DNF_EXIT})"
            warn "  [${NODE_NAME}] Install manually on this node (as root):"
            warn "  [${NODE_NAME}]   ${DNF_CMD}"
            FAILED_NODES+=("${NODE_NAME}/${NODE_IP}")
        fi
        echo ""

    done < <(get_node_ips)

    # ── Summary ──
    echo ""
    echo -e "${BOLD}── Airgap RPM Install Summary ──────────────────────────────────────${RESET}"
    ok "  Installed : ${#SUCCESS_NODES[@]} node(s)${SUCCESS_NODES:+  → ${SUCCESS_NODES[*]}}"
    ok "  Skipped   : ${#SKIPPED_NODES[@]} node(s) (already installed)${SKIPPED_NODES:+  → ${SKIPPED_NODES[*]}}"

    if [[ ${#FAILED_NODES[@]} -gt 0 ]]; then
        warn "  Failed    : ${#FAILED_NODES[@]} node(s) → ${FAILED_NODES[*]}"
        warn ""
        warn "  Fix: on each failed node run as root:"
        warn "    ${DNF_CMD}"
        warn ""
        warn "  Then retry plans:"
        warn "    /usr/lib/k3s-upgrade/apply-upgrade.sh plans-only"
    fi
    echo ""
}

# ── Deploy / update System Upgrade Controller ─────────────────────────────────
deploy_suc() {
    banner "Deploying System Upgrade Controller"

    local SUC_MANIFEST
    SUC_MANIFEST=$(mktemp /tmp/suc-XXXXXX.yaml)
    trap "rm -f ${SUC_MANIFEST}" RETURN

    cp "${MANIFEST_DIR}/system-upgrade-controller.yaml" "${SUC_MANIFEST}"
    kubectl apply -f "${SUC_MANIFEST}"
    ok "SUC manifests applied"

    info "Waiting for system-upgrade-controller to be Ready (timeout: 3 min)..."
    local DEADLINE=$(( $(date +%s) + 180 ))
    while true; do
        local READY
        READY=$(kubectl get deploy system-upgrade-controller \
            -n system-upgrade -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        [[ "${READY:-0}" -ge 1 ]] && break
        [[ $(date +%s) -gt ${DEADLINE} ]] && \
            die "Timeout waiting for SUC. Check: kubectl get pods -n system-upgrade"
        echo -n "."; sleep 5
    done
    echo ""
    ok "system-upgrade-controller is Ready"
    kubectl get pods -n system-upgrade 2>/dev/null || true
}

# ── Apply Upgrade Plans ───────────────────────────────────────────────────────
apply_plans() {
    banner "Applying Upgrade Plans → v${K3S_TARGET_VERSION}"

    local PLAN_MANIFEST
    PLAN_MANIFEST=$(mktemp /tmp/upgrade-plan-XXXXXX.yaml)
    trap "rm -f ${PLAN_MANIFEST}" RETURN

    sed \
        -e "s|K3S_VERSION_PLACEHOLDER|v${K3S_TARGET_VERSION}|g" \
        -e "s|K3S_UPGRADE_IMAGE_PLACEHOLDER|${K3S_UPGRADE_IMAGE}|g" \
        "${MANIFEST_DIR}/upgrade-plan.yaml" > "${PLAN_MANIFEST}"

    kubectl apply -f "${PLAN_MANIFEST}"
    echo ""
    ok "Plans applied"
    kubectl get plans.upgrade.cattle.io -n system-upgrade 2>/dev/null || true
}

# ── Watch upgrade progress ────────────────────────────────────────────────────
watch_upgrade() {
    banner "Watching Upgrade Progress"
    info "Target: v${K3S_TARGET_VERSION}  |  Timeout: ${UPGRADE_TIMEOUT}s  |  Poll: ${UPGRADE_POLL}s"
    info "(Ctrl-C to detach — upgrade continues in background)"
    echo ""

    local DEADLINE=$(( $(date +%s) + UPGRADE_TIMEOUT ))
    local ALL_DONE=false
    local LAST_STATUS=""

    while [[ $(date +%s) -lt ${DEADLINE} ]]; do

        local STATUS_TABLE
        STATUS_TABLE=$(kubectl get nodes \
            -o custom-columns=\
'NAME:.metadata.name,ROLE:.metadata.labels.node-role\.kubernetes\.io/control-plane,VERSION:.status.nodeInfo.kubeletVersion,READY:.status.conditions[-1].status' \
            2>/dev/null || echo "  (cannot reach cluster)")

        if [[ "${STATUS_TABLE}" != "${LAST_STATUS}" ]]; then
            echo -e "\n${BOLD}── $(date '+%H:%M:%S') Node Status ────────────────────────────────────────${RESET}"
            echo "${STATUS_TABLE}"
            LAST_STATUS="${STATUS_TABLE}"
        fi

        local ACTIVE_JOBS
        ACTIVE_JOBS=$(kubectl get jobs -n system-upgrade --no-headers 2>/dev/null \
            | grep -v "Complete" || true)
        if [[ -n "${ACTIVE_JOBS}" ]]; then
            echo -e "\n${BOLD}── Active Upgrade Jobs:${RESET}"
            kubectl get jobs -n system-upgrade 2>/dev/null || true
        fi

        local FAILED_PODS
        FAILED_PODS=$(kubectl get pods -n system-upgrade --no-headers 2>/dev/null \
            | grep -E "Error|CrashLoop|OOMKilled|ErrImagePull|ImagePullBackOff" || true)
        if [[ -n "${FAILED_PODS}" ]]; then
            warn "Failed pods detected in system-upgrade namespace:"
            echo "${FAILED_PODS}"
            warn "  Likely cause: k3s-upgrade or airgap image not in containerd on that node"
            warn "  Check: ssh root@<node-ip> \"crictl images | grep -E 'k3s-upgrade|k3s-airgap'\""
            warn "  Logs : kubectl logs -n system-upgrade <pod-name>"
        fi

        local NODES_NOT_TARGET
        NODES_NOT_TARGET=$(kubectl get nodes \
            -o jsonpath='{.items[*].status.nodeInfo.kubeletVersion}' 2>/dev/null \
            | tr ' ' '\n' \
            | grep -v "^v${K3S_TARGET_VERSION}$" \
            | grep -v "^$" \
            | wc -l || echo "99")

        if [[ "${NODES_NOT_TARGET}" -eq 0 ]]; then
            ALL_DONE=true
            break
        fi

        local REMAINING=$(( DEADLINE - $(date +%s) ))
        info "Waiting... ${NODES_NOT_TARGET} node(s) not yet on v${K3S_TARGET_VERSION} | ${REMAINING}s left"
        sleep "${UPGRADE_POLL}"
    done

    echo ""
    if ${ALL_DONE}; then
        echo -e "${GREEN}${BOLD}"
        echo "  ╔══════════════════════════════════════════════════════╗"
        echo "  ║  UPGRADE COMPLETE — All nodes on v${K3S_TARGET_VERSION}        ║"
        echo "  ╚══════════════════════════════════════════════════════╝"
        echo -e "${RESET}"
        kubectl get nodes -o wide
    else
        warn "Watch timed out. Upgrade may still be running in background."
        warn "Re-attach : /usr/lib/k3s-upgrade/apply-upgrade.sh watch"
        warn "Status    : /usr/lib/k3s-upgrade/apply-upgrade.sh status"
        kubectl get nodes
    fi
}

# ── Status ────────────────────────────────────────────────────────────────────
show_status() {
    export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
    banner "Upgrade Status"

    echo -e "${BOLD}Nodes:${RESET}"
    kubectl get nodes -o wide 2>/dev/null || echo "  (cannot reach cluster)"

    echo -e "\n${BOLD}Upgrade Plans:${RESET}"
    kubectl get plans.upgrade.cattle.io -n system-upgrade 2>/dev/null || echo "  (none)"

    echo -e "\n${BOLD}Upgrade Jobs:${RESET}"
    kubectl get jobs -n system-upgrade 2>/dev/null || echo "  (none)"

    echo -e "\n${BOLD}Upgrade Pods:${RESET}"
    kubectl get pods -n system-upgrade 2>/dev/null || echo "  (none)"

    echo -e "\n${BOLD}SUC Controller:${RESET}"
    kubectl get deploy system-upgrade-controller -n system-upgrade 2>/dev/null \
        || echo "  (not deployed)"

    echo -e "\n${BOLD}Version info:${RESET}"
    echo "  Target version : v${K3S_TARGET_VERSION}"
    echo "  Airgap RPM URL : ${K3S_AIRGAP_RPM_URL}"
    echo "  k3s upgrade img: ${K3S_UPGRADE_IMAGE}"
    echo "  SUC kubectl img: ${SUC_KUBECTL_IMAGE}"

    echo -e "\n${BOLD}Version env:${RESET}"
    cat /etc/k3s-upgrade/version.env 2>/dev/null | sed 's/^/  /' || echo "  (not found)"

    echo -e "\n${BOLD}Airgap RPM installed on each node:${RESET}"
    while IFS=$'\t' read -r NODE_NAME NODE_IP; do
        [[ -z "${NODE_IP}" ]] && continue
        if check_ssh "${NODE_IP}" 2>/dev/null; then
            local PKG
            PKG=$(ssh ${SSH_OPTS} -p "${SSH_PORT}" "${SSH_USER}@${NODE_IP}" \
                "rpm -qa 2>/dev/null | grep -i 'k3s-airgap-images' || echo 'NOT INSTALLED'" 2>/dev/null)
            echo "  [${NODE_NAME}] ${PKG}"
        else
            echo "  [${NODE_NAME}] SSH unreachable"
        fi
    done < <(get_node_ips)
}

# ── Rollback ──────────────────────────────────────────────────────────────────
do_rollback() {
    export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
    banner "Rollback — Removing Upgrade Plans"

    warn "Removes Plans, stopping any pending node upgrades."
    warn "Nodes already upgraded to v${K3S_TARGET_VERSION} are NOT downgraded."
    warn "To downgrade: dnf install k3s-upgrade-v<previous-version>"
    echo ""

    kubectl delete plans.upgrade.cattle.io k3s-server-upgrade k3s-agent-upgrade \
        -n system-upgrade --ignore-not-found
    ok "Plans removed"

    echo ""
    info "Current node versions:"
    kubectl get nodes \
        -o custom-columns='NAME:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion'
}

# ── Entrypoint ────────────────────────────────────────────────────────────────
CMD="${1:-apply}"
case "${CMD}" in
    apply)
        preflight
        install_airgap_rpm
        deploy_suc
        apply_plans
        watch_upgrade
        ;;
    stage-images)
        export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
        preflight
        install_airgap_rpm
        ;;
    suc-only)
        export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
        preflight
        deploy_suc
        ;;
    plans-only)
        export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
        preflight
        apply_plans
        ;;
    status)
        show_status
        ;;
    rollback)
        do_rollback
        ;;
    watch)
        export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
        watch_upgrade
        ;;
    *)
        echo ""
        echo "Usage: $0 {apply|stage-images|suc-only|plans-only|status|rollback|watch}"
        echo ""
        echo "  apply        Full flow: install airgap RPM on nodes + deploy SUC + apply Plans + watch"
        echo "  stage-images Install k3s airgap image RPM on all nodes only (SSH + dnf)"
        echo "  suc-only     Deploy/update System Upgrade Controller only"
        echo "  plans-only   Apply upgrade Plans only (SUC must already be running)"
        echo "  status       Show nodes, Plans, Jobs, per-node airgap RPM install state"
        echo "  rollback     Remove upgrade Plans (halts further upgrades)"
        echo "  watch        Re-attach to live upgrade progress monitor"
        echo ""
        echo "Environment variables:"
        echo "  KUBECONFIG       kubeconfig path         (default: /etc/rancher/k3s/k3s.yaml)"
        echo "  SSH_USER         SSH login user          (default: root)"
        echo "  SSH_KEY          SSH private key path    (default: ssh-agent)"
        echo "  SSH_PORT         SSH port                (default: 22)"
        echo "  NEXUS_USER       Nexus auth username     (optional, for protected repos)"
        echo "  NEXUS_PASS       Nexus auth password     (optional, for protected repos)"
        echo "  UPGRADE_TIMEOUT  Max watch seconds       (default: 1800)"
        exit 1
        ;;
esac
