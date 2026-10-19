#!/bin/bash
# Build amdgpu.ko for the base image kernel with the MacPro6,1 SI DPM patch
set -ouex pipefail

KVER=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-core)
# kernel-core 7.2.9-ogc3.1.fc44 is built from OGC tag v7.2.9-ogc3
TAG="v$(rpm -q --qf '%{VERSION}-%{RELEASE}' kernel-core | sed -E 's/\.[0-9]+\.fc[0-9]+$//')"

dnf5 install -y gcc make flex bison elfutils-libelf-devel openssl-devel git-core

git clone --depth 1 --filter=blob:none --sparse -b "$TAG" https://github.com/OpenGamingCollective/linux.git /src
git -C /src sparse-checkout set drivers/gpu/drm
git -C /src apply /amdgpu/macpro61-amdgpu-si-dpm-performance.patch

# Trace headers include ../../drivers/gpu/drm/amd/... relative to the kernel tree
rm -rf "/usr/src/kernels/$KVER/drivers/gpu/drm/amd"
ln -s /src/drivers/gpu/drm/amd "/usr/src/kernels/$KVER/drivers/gpu/drm/amd"

make -C "/usr/src/kernels/$KVER" M=/src/drivers/gpu/drm/amd/amdgpu -j"$(nproc)" modules
mkdir -p /out
strip --strip-debug -o /out/amdgpu.ko /src/drivers/gpu/drm/amd/amdgpu/amdgpu.ko
