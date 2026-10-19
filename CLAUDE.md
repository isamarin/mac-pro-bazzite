# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A custom [bootc](https://github.com/bootc-dev/bootc) OS image of Bazzite (`ghcr.io/ublue-os/bazzite:stable`) for the Mac Pro 6,1 (Late 2013) with dual FirePro D700, derived from the Universal Blue `image-template`. Published as `ghcr.io/isamarin/mac-pro-bazzite`. The output is an OCI container image pushed to GHCR that machines switch to with `bootc switch`. There is no application code — changes are about what goes into the OS image.

## Commands

All tasks run through `just` (reads variables from `image-template.env`). Requires `podman`, plus `skopeo` and `jq` for `just build`; disk/VM recipes also need root podman and `bootc-image-builder`.

- `just build` — build the container image locally (`podman build -f Containerfile`), tagged `<IMAGE_NAME>:<DEFAULT_TAG>`
- `just build-qcow2` / `build-raw` / `build-iso` — build a disk image from `localhost/<image>` via bootc-image-builder into `output/`; `rebuild-*` does `build` first
- `just run-vm-qcow2` (alias `run-vm`) — boot the disk image in a VM; `just spawn-vm` uses systemd-vmspawn
- `just lint` — shellcheck all `*.sh`; `just format` — shfmt them
- `just check` / `just fix` — check/fix Justfile formatting
- `just clean` — remove `output/` and build leftovers

There are no tests. The real validation is the final `RUN bootc container lint` in the `Containerfile`, which fails the build if the image is not a valid bootc image.

## How the image is assembled

1. `Containerfile` stage `ctx` (FROM scratch) holds `build_files/`, `system_files/` and the akmods RPMs (`/akmods`) so they are bind-mounted during build but not copied into the final image.
2. The main stage starts from `BASE_IMAGE` (an `ARG` at the top of `Containerfile`) and runs `/ctx/build.sh` with caches on `/var/cache`, `/var/log` and a tmpfs `/tmp`.
3. `build_files/build.sh` first copies `system_files/` over `/` (so `system_files/etc/...` → `/etc/...`, `system_files/usr/...` → `/usr/...`), then installs packages with `dnf5` and enables systemd units. Put package installs, COPR enables (disable them again afterwards so they don't ship enabled) and `systemctl enable` here.
4. Mac Pro specifics:
   - Wi-Fi (Broadcom BCM4360) needs the `wl` driver, which stock Bazzite does not ship. `build.sh` installs `broadcom-wl` + `kmod-wl` from `ghcr.io/ublue-os/akmods:<AKMODS_TAG>`. The kmod is built for one exact kernel, so `just build` reads the base image's `ostree.linux` label with `skopeo` and passes `AKMODS_TAG=ogc-<fedora>-<kernel>`. Plain `podman build` without that build arg fails. Do not use the floating `ogc-44` tag; it can be ahead of `bazzite:stable`.
   - The D700 (Tahiti, GCN 1.0) is switched from `radeon` to `amdgpu` through `system_files/usr/lib/bootc/kargs.d/10-macpro-amdgpu.toml`. kargs.d is applied on `bootc switch`/`bootc upgrade`, so install with `bootc switch`, not `rpm-ostree rebase`.
5. Static config files belong in `system_files/`, not in heredocs in `build.sh`. Prefer `/usr` over `/etc`; `/var` and `/opt` are not reliably preserved by bootc deploys (see the commented `/opt` note in `Containerfile`).

## Configuration

- `image-template.env` — `IMAGE_NAME`, `REPO_ORGANIZATION`, description/keywords/logo, `DEFAULT_TAG`, `BIB_IMAGE`. `IMAGE_NAME` drives the GHCR image name and the Justfile's OCI/ArtifactHub labels.
- `disk_config/*.toml` — bootc-image-builder configs. `disk.toml` is used for qcow2/raw; `iso.toml` (KDE installer) is used for ISOs, and its kickstart runs `bootc switch` to this image.

## CI (`.github/workflows/`)

- `build.yml` — on push/PR to `main`, daily cron and manual dispatch: `just build`, then `just ostree-rechunk`, then push to `ghcr.io/<owner>/<IMAGE_NAME>` and sign with cosign using the `SIGNING_SECRET` repo secret (push/sign skipped on PRs). Consumers verify with `cosign.pub`, which must be generated and committed (it is not in the repo yet).
- `build-disk.yml` — manual dispatch: builds `qcow2` and `anaconda-iso` disk images (amd64 or arm64) and uploads them as job artifacts or to S3 (`S3_*` secrets).
- Dependency pinning is maintained by Renovate/Dependabot; GitHub Actions are pinned by commit SHA.

