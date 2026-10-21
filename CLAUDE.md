# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A custom [bootc](https://github.com/bootc-dev/bootc) OS image of Bazzite GNOME (`ghcr.io/ublue-os/bazzite-gnome:stable`) for the Mac Pro 6,1 (Late 2013) with dual FirePro D700, derived from the Universal Blue `image-template`. Published as `ghcr.io/isamarin/mac-pro-bazzite`. The output is an OCI container image pushed to GHCR that machines switch to with `bootc switch`. There is no application code — changes are about what goes into the OS image.

## Commands

All tasks run through `just` (reads variables from `image-template.env`). Requires `podman`; disk/VM recipes also need root podman and `bootc-image-builder`.

- `just build` — build the container image locally (`podman build -f Containerfile`), tagged `<IMAGE_NAME>:<DEFAULT_TAG>`
- `just build-qcow2` / `build-raw` / `build-iso` — build a disk image from `localhost/<image>` via bootc-image-builder into `output/`; `rebuild-*` does `build` first
- `just run-vm-qcow2` (alias `run-vm`) — boot the disk image in a VM; `just spawn-vm` uses systemd-vmspawn
- `just lint` — shellcheck all `*.sh`; `just format` — shfmt them
- `just check` / `just fix` — check/fix Justfile formatting
- `just clean` — remove `output/` and build leftovers

There are no tests. The real validation is the final `RUN bootc container lint` in the `Containerfile`, which fails the build if the image is not a valid bootc image.

## How the image is assembled

1. `Containerfile` stage `amdgpu` (FROM the base image) runs `amdgpu/build.sh` to build a patched `amdgpu.ko`. Stage `ctx` (FROM scratch) holds `build_files/`, `system_files/` and that module (`/amdgpu`), so they are bind-mounted during build but not copied into the final image.
2. The main stage starts from `BASE_IMAGE` (`bazzite-gnome:stable`, an `ARG` at the top of `Containerfile`) and runs `/ctx/build.sh` with caches on `/var/cache`, `/var/log` and a tmpfs `/tmp`.
3. `build_files/build.sh` first copies `system_files/` over `/` (so `system_files/etc/...` → `/etc/...`, `system_files/usr/...` → `/usr/...`), then installs packages with `dnf5` and enables systemd units. Put package installs, COPR enables (disable them again afterwards so they don't ship enabled) and `systemctl enable` here.
4. Mac Pro specifics:
   - Wi-Fi (Broadcom BCM4360): Bazzite already ships `broadcom-wl` + `kmod-wl` but blacklists `wl` with `/etc/modprobe.d/default-disable-broadcom-wl.conf`. `build.sh` deletes that file, and the build fails if `wl.ko` disappears from the base image (Bazzite has dropped it before).
   - GPU: kernel 7.x binds the D700 (Tahiti, SI) to `amdgpu` by default, and RADV Vulkan works, so no kernel args are needed. However, on MacPro6,1 the SI DPM keeps both cards at 300 MHz core / 150 MHz memory even under load, and `high`/`performance` do not help on the stock kernel.
     - `amdgpu/build.sh` fixes this. It sparse-clones `drivers/gpu/drm` from `OpenGamingCollective/linux` at the tag matching the base image's `kernel-core` (`7.2.9-ogc3.1` → `v7.2.9-ogc3`), applies `amdgpu/macpro61-amdgpu-si-dpm-performance.patch` (from flammafex/linux-mac), builds it with `M=` against the base image's `kernel-devel`, and strips it. Without the symlink of `amd/` into the kernel-devel tree, the trace headers fail to compile.
     - `build.sh` overwrites the stock `amdgpu.ko`, then runs `depmod` and regenerates the initramfs, which contains amdgpu.
    - The patch only takes effect in the `performance` power state, and in that state the card stays at top clocks even idle. The udev rule `system_files/usr/lib/udev/rules.d/90-macpro-gpu-performance.rules` sets it at boot on the display card 06:00.0 only; the compute card 02:00.0 stays `balanced` (300/150 MHz) to run cooler.
   - Fan: the SMC curve favours silence, so `usr/lib/udev/rules.d/90-macpro-fan.rules` raises `fan1_min` to 1300 rpm; the SMC still controls the fan above that.
     - Kernel module signing is not enforced: no Secure Boot on this Mac, and lockdown is `none`.
   - Suspend is masked in `build.sh`: the machine hung on resume from deep suspend, and it runs always-on services.
5. Server stack:
   - Docker (`moby-engine`, `docker-compose`) and nginx are installed and enabled in `build.sh`. The same file opens port 80 with `firewall-offline-cmd`; the default FedoraWorkstation zone already allows 1025-65535, which covers 2222 and 8123.
     - `firewall-offline-cmd` only edits the image's `/etc`. A machine whose zone file was already changed locally keeps its own copy, so on the running Mac Pro `http` was added by hand with `firewall-cmd --permanent`.
     - `etc/docker/daemon.json` sets `ip-forward-no-drop`. Without it Docker sets the iptables `FORWARD` policy to `DROP`, which silently blocks new connections to podman's published ports (GitLab SSH on 2222) while netavark's own rules look fine.
   - GitLab CE and Home Assistant are podman quadlets in `system_files/etc/containers/systemd/`, not Docker containers. They live in `/etc` so the GitLab `external_url` can be edited on the machine, and their data is in named podman volumes.
     - GitLab is pinned to an exact version: a backup restores only into the same version. It was moved here from the MacBook on 2026-10-20 (backup + `gitlab-secrets.json`), on the `gitlab19-*` volumes; `external_url` is `http://192.168.1.127` because CI containers and other devices do not resolve `.local`. Upgrade by bumping the tag one minor at a time.
     - The CI runner `mac-pro-docker` is a Docker container (`docker run --restart unless-stopped`, volume `gitlab-runner-config`, mounts the Docker socket), so jobs run in Docker, not podman. CI images `lumina-ci/node-uv:1` and `lumina-ci/tauri:1` are built locally on the machine from `~/gitlab-ci/images`.
   - GitLab HTTP listens on `127.0.0.1:8929` behind nginx (`etc/nginx/conf.d/gitlab.conf`, `default_server` on :80), and GitLab SSH is on port 2222. The `nginx.service.d` drop-in turns on the SELinux boolean `httpd_can_network_connect`; without it the proxy returns 502.
   - Home Assistant uses host networking and is served directly on :8123.
   - lumina-world (tile build cluster, this machine is node `igrs.lumina.node.0`): `postgis.container` (PostGIS 17-3.5, pinned) publishes 5432 on 127.0.0.1 and 192.168.1.127 only, with `pg_hba` limited to 192.168.1.0/24 and the podman network; `lumina-world-worker.container` runs the node image `docker.io/lumina-world/node:latest` (`Pull=never`), which `lumina-world/images/build.sh` builds with docker and loads into podman. Secrets live in `/etc/lumina-world/{postgis,node}.env` (0600, not in the image), data in `/var/lib/lumina-world`.
6. Static config files belong in `system_files/`, not in heredocs in `build.sh`. Prefer `/usr` over `/etc`; `/var` and `/opt` are not reliably preserved by bootc deploys (see the commented `/opt` note in `Containerfile`).

## Configuration

- `image-template.env` — `IMAGE_NAME`, `REPO_ORGANIZATION`, description/keywords/logo, `DEFAULT_TAG`, `BIB_IMAGE`. `IMAGE_NAME` drives the GHCR image name and the Justfile's OCI/ArtifactHub labels.
- `disk_config/*.toml` — bootc-image-builder configs. `disk.toml` is used for qcow2/raw; `iso.toml` (GNOME installer) is used for ISOs, and its kickstart runs `bootc switch` to this image.

## CI (`.github/workflows/`)

- `build.yml` — on push/PR to `main`, daily cron and manual dispatch: `just build`, then `just ostree-rechunk`, then push to `ghcr.io/<owner>/<IMAGE_NAME>` and sign with cosign using the `SIGNING_SECRET` repo secret (push/sign skipped on PRs). Consumers verify with `cosign.pub`, which must be generated and committed (it is not in the repo yet).
- `build-disk.yml` — manual dispatch: builds `qcow2` and `anaconda-iso` disk images (amd64 or arm64) and uploads them as job artifacts or to S3 (`S3_*` secrets).
- Dependency pinning is maintained by Renovate/Dependabot; GitHub Actions are pinned by commit SHA.

