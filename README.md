Prerequisites (build machine only)
bash# Install rpmbuild toolchain
dnf install -y rpm-build rpmdevtools

# Verify
rpmbuild --version

1 — Create the rpmbuild directory tree
bash# Creates ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
rpmdev-setuptree

# Confirm the macro is set
cat ~/.rpmmacros
# Should show: %_topdir /root/rpmbuild  (or /home/<user>/rpmbuild)

2 — Copy source files into the rpmbuild tree
bash# Assumes you cloned/copied this repo to /opt/k3s-upgrade-rpm
REPO=/opt/k3s-upgrade-rpm

mkdir -p ~/rpmbuild/SOURCES/scripts
mkdir -p ~/rpmbuild/SOURCES/manifests

cp ${REPO}/SOURCES/scripts/apply-upgrade.sh                  ~/rpmbuild/SOURCES/scripts/
cp ${REPO}/SOURCES/manifests/upgrade-plan.yaml               ~/rpmbuild/SOURCES/manifests/
cp ${REPO}/SOURCES/manifests/system-upgrade-controller.yaml  ~/rpmbuild/SOURCES/manifests/
cp ${REPO}/SPECS/k3s-upgrade.spec                            ~/rpmbuild/SPECS/

# Verify
find ~/rpmbuild/SOURCES ~/rpmbuild/SPECS -type f

3 — Build the RPM
bashrpmbuild -ba ~/rpmbuild/SPECS/k3s-upgrade.spec \
    --define "k3s_version           1.33.3" \
    --define "k3s_airgap_rpm_url    https://nexus.company.com/repository/k3s/k3s/v1.33.3/k3s-airgap-images-1.33.3.rpm" \
    --define "k3s_upgrade_image     nexus.company.com:5000/rancher/k3s-upgrade:v1.33.3-k3s1" \
    --define "suc_controller_image  nexus.company.com:5000/rancher/system-upgrade-controller:v0.14.1" \
    --define "suc_kubectl_image     nexus.company.com:5000/rancher/kubectl:v1.33.3"

-ba builds both the binary RPM (.rpm) and source RPM (.src.rpm). Use -bb if you only want the binary RPM.


4 — Verify the built RPM
bash# Find it
find ~/rpmbuild/RPMS -name "*.rpm"
# → ~/rpmbuild/RPMS/noarch/k3s-upgrade-v1.33.3-1.33.3-1.noarch.rpm

RPM=~/rpmbuild/RPMS/noarch/k3s-upgrade-v1.33.3-1.33.3-1.noarch.rpm

# Package info
rpm -qip ${RPM}

# List all files inside the RPM
rpm -qlp ${RPM}

# View the %post / %pre scriptlets
rpm -qp --scripts ${RPM}

# Confirm all values were baked in correctly
rpm2cpio ${RPM} | cpio -idm --quiet
grep -E "^K3S_TARGET_VERSION=|^K3S_UPGRADE_IMAGE=|^K3S_AIRGAP_RPM_URL=|^SUC_" \
    usr/lib/k3s-upgrade/apply-upgrade.sh
cat etc/k3s-upgrade/version.env

5 — Push RPM to Nexus
bashRPM=~/rpmbuild/RPMS/noarch/k3s-upgrade-v1.33.3-1.33.3-1.noarch.rpm

curl -u admin:PASSWORD \
     --upload-file ${RPM} \
     https://nexus.company.com/repository/rhel9-local/$(basename ${RPM})

6 — Install on the k3s server node
bash# Option A — from Nexus dnf repo (if the repo is configured in /etc/yum.repos.d/)
dnf install -y k3s-upgrade-v1.33.3

# Option B — from local file (if you SCP'd the RPM directly)
dnf install -y /tmp/k3s-upgrade-v1.33.3-1.33.3-1.noarch.rpm

# With SSH key + Nexus auth for the airgap RPM
SSH_KEY=/root/.ssh/id_ed25519 \
NEXUS_USER=admin \
NEXUS_PASS=secret \
    dnf install -y k3s-upgrade-v1.33.3

Or — one-shot using the wrapper script
If you want to skip the manual steps above, build-rpm.sh does steps 2–5 in one go:
bashcd /opt/k3s-upgrade-rpm

K3S_VERSION=1.33.3 \
K3S_AIRGAP_IMAGE_URL=https://nexus.company.com/repository/k3s/k3s/v1.33.3/k3s-airgap-images-1.33.3.rpm \
K3S_UPGRADE_IMAGE=nexus.company.com:5000/rancher/k3s-upgrade:v1.33.3-k3s1 \
SUC_KUBECTL_IMAGE=nexus.company.com:5000/rancher/kubectl:v1.33.3 \
NEXUS_RPM_REPO=https://nexus.company.com/repository/rhel9-local \
NEXUS_USER=admin \
NEXUS_PASS=secret \
    ./build-rpm.sh Sonnet 4.6
