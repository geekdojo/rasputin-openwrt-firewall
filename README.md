# rasputin-openwrt-firewall

[![Release](https://github.com/geekdojo/rasputin-openwrt-firewall/actions/workflows/release.yml/badge.svg)](https://github.com/geekdojo/rasputin-openwrt-firewall/actions/workflows/release.yml)
[![Latest](https://img.shields.io/github/v/release/geekdojo/rasputin-openwrt-firewall?include_prereleases&label=release)](https://github.com/geekdojo/rasputin-openwrt-firewall/releases)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-E8590C.svg)](LICENSE)

The firewall of **Rasputin** — an open-source homelab cluster system: a small
fleet of nodes (Raspberry Pi or Intel N100) plus a dedicated firewall node,
managed from one web UI, with atomic A/B OS updates that roll back on
failure. Opinionated where you want guidance, open where you want control,
and built to work in the first hour.

> **Want to run Rasputin, not build it?** Flashable images and a four-step
> quickstart live in
> [`rasputin-releases`](https://github.com/geekdojo/rasputin-releases).

This repo builds the OpenWrt-based firewall image for the Rasputin **Node N**
(Intel N100 + dual 2.5GbE Intel i226-V). One repo, one SKU
(`rasputin-fw-n100`): OpenWrt **ImageBuilder** produces the rootfs (minutes,
not hours), and a genimage post-process re-lays it out into an **A/B disk**
with the same GRUB-boot-counter rollback contract as the compute nodes.

> **Status: pre-alpha.** Rasputin is in its commodity-hardware proof phase.
> Image layout, update artifacts, and provisioning formats change without
> notice.

Rasputin is a modular, node-based homelab system; the system-level overview
lives in
[ARCHITECTURE.md](https://github.com/geekdojo/rasputin-control-plane/blob/main/ARCHITECTURE.md)
in the `rasputin-control-plane` repo. The compute and controlplane nodes run
the Buildroot-based [`rasputin-os`](https://github.com/geekdojo/rasputin-os)
image — different toolchain, different update mechanism, same statically
linked `rasputin-agent` binary on both.

The firewall is deliberately x86-only: a Raspberry Pi can't be this node
(one PCIe lane, 5 W PCIe budget, single 1GbE PHY).

## What the image is

- **OpenWrt 25.12 x86/64**, built with ImageBuilder from `packages.txt` + the
  `files/` overlay. Reference hardware: CWWK x86-p5-n100.
- **A/B slots + GRUB boot counter.** `scripts/assemble-ab-image.sh` extracts
  the kernel and rootfs squashfs from ImageBuilder's combined-EFI output,
  builds a GRUB EFI with the `loadenv`/`test` modules the boot counter needs,
  and assembles a GPT disk: ESP + two rootfs slots + a shared `rootfs_data`
  partition. `/overlay` (all OpenWrt config) lives on the shared partition
  via extroot, so **configuration survives a slot switch**, and the data
  partition grows to fill the disk on first boot.
- **Updates ride the control plane's normal update saga.** The OTA artifact
  is a bare rootfs squashfs; the agent's OpenWrt A/B backend writes it to the
  inactive slot, flips the GRUB environment, reboots, and the control plane
  commits on a role-aware health check (nftables ruleset + DNS up) or rolls
  back. RAUC itself isn't used here — it isn't in the OpenWrt feeds — but the
  bootloader contract is byte-for-byte the compute image's. *Honest gap:*
  cryptographic signature verification of the OTA rootfs is not wired yet;
  transport integrity currently comes from SHA verification over the
  encrypted mesh.
- **IDS: snort3 in tap mode, detection-only.** Snort3 Community Rules are
  hash-pinned and baked at build time (`scripts/fetch-snort-rules.sh`);
  alerts flow through the agent to the control plane UI and log store. Tap
  mode leaves the kernel's forwarding fast path (flow offloading)
  undisturbed. **An N100 cannot do inline IPS at 1 Gbps line rate**, so we
  ship detection-only rather than pretend otherwise.
- **Declarative config from the control plane.** The agent applies intent
  (port forwards, rules, VPN peers) via ubus/UCI, reports a state hash, and
  out-of-band edits are detected — not clobbered. SSH (key-only; no baked
  key = password auth stays off the menu for production images) and LuCI
  remain first-class escape hatches.
- **IPv6 is disabled by design** — the whole Rasputin stack is IPv4-only for
  now.

## Layout

```
.github/workflows/release.yml         validate → ImageBuilder build → A/B
                                      assemble → QEMU/OVMF smoke → sign → release
.github/workflows/canary.yml          scheduled build canary (catches upstream drift)
scripts/init-imagebuilder.sh          download + verify the pinned OpenWrt ImageBuilder
scripts/assemble-ab-image.sh          combined-efi image → A/B GPT disk + .rootfs OTA artifact
scripts/fetch-snort-rules.sh          hash-pinned snort3 ruleset fetch (run before build)
packages.txt                          package list passed to `make image`
agent-version.txt                     pinned rasputin-agent release version
image/genimage.cfg, image/grub.cfg    A/B disk layout + boot-counter GRUB config
files/                                overlay applied to every image:
├── etc/rasputin/                     seed template, trust anchors
├── etc/init.d/rasputin-agent         procd service
├── etc/uci-defaults/                 one-shot first-boot seed (WAN/LAN ports,
│                                     flow offload, agent enablement)
└── usr/lib/rasputin/apply-seed       seed.env → UCI sync, re-runnable
```

`files/usr/bin/rasputin-agent` is **not committed** — CI fetches the release
binary pinned in `agent-version.txt` from
[`rasputin-control-plane`](https://github.com/geekdojo/rasputin-control-plane)
releases.

## Quick start (dev)

> **Host OS:** ImageBuilder needs Linux. On a Mac, build inside a Linux
> VM/container or use the CI workflow (~5–10 min per build).

```sh
git clone https://github.com/geekdojo/rasputin-openwrt-firewall
cd rasputin-openwrt-firewall
./scripts/init-imagebuilder.sh        # downloads the pinned OpenWrt ImageBuilder

# Fetch the pinned agent release binary into the overlay:
mkdir -p files/usr/bin
gh release download "v$(cat agent-version.txt)" \
  --repo geekdojo/rasputin-control-plane \
  --pattern "rasputin-agent-$(cat agent-version.txt)-linux-amd64.tar.gz" --dir /tmp
tar -xzf /tmp/rasputin-agent-*-linux-amd64.tar.gz -C files/usr/bin
chmod +x files/usr/bin/rasputin-agent

# Baked IDS rules:
./scripts/fetch-snort-rules.sh

# Build the OpenWrt image:
cd imagebuilder
make image PROFILE=generic \
  PACKAGES="$(tr '\n' ' ' < ../packages.txt)" \
  FILES="$(realpath ../files)" \
  EXTRA_IMAGE_NAME=rasputin
cd ..

# Re-layout into the A/B disk + OTA artifact:
gunzip -k imagebuilder/bin/targets/x86/64/openwrt-*-rasputin-*-combined-efi.img.gz
./scripts/assemble-ab-image.sh imagebuilder/bin/targets/x86/64/openwrt-*-combined-efi.img
# → ab-out/rasputin-fw-n100-<ver>-ab.img.gz   (flash this)
# → ab-out/rasputin-fw-n100-<ver>.rootfs      (OTA artifact)
```

## Provisioning a flashed node

Edit `/etc/rasputin/seed.env` on the device (or pre-seed it before first
boot):

```sh
RASPUTIN_NODE_ROLE=firewall
RASPUTIN_NATS_URL=nats://rasputin.local:4222
RASPUTIN_CP_JOIN_TOKEN=...            # minted by the controlplane
```

On first boot the uci-defaults one-shot assigns WAN/LAN ports (eth1 = WAN,
eth0 = LAN on the reference hardware), enables nftables flow offload,
starts the agent, and syncs the seed into UCI. Re-run
`/usr/lib/rasputin/apply-seed` any time the seed changes; if the seed is
blank the agent simply waits. Enrollment is normally driven from the control
plane's Add-node flow.

## Releases

CI builds, boot-smokes the A/B disk under QEMU/OVMF (the boot-counter menu
itself is part of the smoke), signs, and publishes to GitHub Releases.
Versioning is CalVer (`YYYY.MM.MICRO`, `-dev.N` for prereleases), on the
same version line as the sibling repos.

## Contributing

Issues and discussion are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md)
for the PR flow and the CLA (signing is automatic on your first PR).

## AI-assisted development

This project is developed by a human maintainer working with AI coding assistants;
AI-assisted commits carry `Co-Authored-By` trailers naming the model. Approach,
accountability, and provenance: [AI_DISCLOSURE.md](AI_DISCLOSURE.md).

## License

[AGPL-3.0](LICENSE) — this covers the build tooling, scripts, and
configuration in this repository. The OpenWrt distribution and the upstream
packages the image assembles retain their own licenses.
