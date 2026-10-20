#!/bin/bash

set -ouex pipefail

# Copy the contents of system_files/ of the git repo to /
cp -avf "/ctx/system_files"/. /

### Mac Pro 6,1: Broadcom BCM4360 Wi-Fi. Bazzite ships wl but blacklists it; fail the build if it stops shipping it
[ -n "$(find /usr/lib/modules -name 'wl.ko*')" ]
rm -f /etc/modprobe.d/default-disable-broadcom-wl.conf

### Mac Pro 6,1: patched amdgpu (SI DPM fix) replaces the stock module, initramfs included
KVER=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-core)
install -m644 /ctx/amdgpu/amdgpu.ko "/usr/lib/modules/$KVER/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko"
depmod -a "$KVER"
dracut --no-hostonly --kver "$KVER" --reproducible --add ostree -f "/usr/lib/modules/$KVER/initramfs.img"
chmod 0600 "/usr/lib/modules/$KVER/initramfs.img"

### Mac Pro 6,1: gamemode raises the display D700 to "performance" only while a game runs (/etc/gamemode.ini)
dnf5 install -y gamemode

### Always-on server: resume from deep suspend hangs this machine
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

### Server stack: Docker, nginx (proxy for GitLab); GitLab and Home Assistant run as quadlets from /etc/containers/systemd
dnf5 install -y moby-engine docker-compose nginx
systemctl enable docker.service nginx.service
# 2222 and 8123 are already open: the FedoraWorkstation zone allows 1025-65535
firewall-offline-cmd --add-service=http

### Install packages

# Packages can be installed from any enabled yum repo on the image.
# RPMfusion repos are available by default in ublue main images
# List of rpmfusion packages can be found here:
# https://mirrors.rpmfusion.org/mirrorlist?path=free/fedora/updates/43/x86_64/repoview/index.html&protocol=https&redirect=1

# this installs a package from fedora repos
dnf5 install -y tmux

# Use a COPR Example:
#
# dnf5 -y copr enable ublue-os/staging
# dnf5 -y install package
# Disable COPRs so they don't end up enabled on the final image:
# dnf5 -y copr disable ublue-os/staging

#### Example for enabling a System Unit File

systemctl enable podman.socket
