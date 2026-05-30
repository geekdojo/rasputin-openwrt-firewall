# rasputin-openwrt-firewall

OpenWrt-based firewall image for the Rasputin **Node N** (Intel N100 + dual
2.5GbE Intel i226-V). One repo, one SKU (`rasputin-fw-n100`), built via
**OpenWrt ImageBuilder** (download-prebuilt-rootfs + apply package list +
files overlay — minutes, not hours).

> The compute and controlplane nodes run the Buildroot-based **Rasputin OS**
> image — see the [`rasputin-os`](https://github.com/geekdojo/rasputin-os)
> repo. Different toolchain, different update mechanism (RAUC vs `sysupgrade`),
> same `rasputin-agent` binary on both ([buildroot-os.md §5](https://github.com/geekdojo/geekdojo-wiki/blob/main/projects/rasputin/design/os-images/buildroot-os.md)
> confirmed CGO_ENABLED=0 static Go runs on both glibc and musl).

## Design docs (source of truth)

- [OS Images — Overview](https://github.com/geekdojo/geekdojo-wiki/blob/main/projects/rasputin/design/os-images/overview.md)
- [Firewall Image](https://github.com/geekdojo/geekdojo-wiki/blob/main/projects/rasputin/design/os-images/firewall-image.md) — this repo's build-and-release spec
- [Release Pipeline](https://github.com/geekdojo/geekdojo-wiki/blob/main/projects/rasputin/design/os-images/release-pipeline.md)
- [Provisioning & Role-at-Runtime](https://github.com/geekdojo/geekdojo-wiki/blob/main/projects/rasputin/design/os-images/provisioning.md)

## Status

**Scaffold (2026-05-30).** Repo structure + CI in place but **not yet
hardware-validated** — the boards haven't arrived. The build target is
OpenWrt x86/64 generic profile, `EXTRA_IMAGE_NAME=rasputin`, packages per
[firewall-image.md §2](https://github.com/geekdojo/geekdojo-wiki/blob/main/projects/rasputin/design/os-images/firewall-image.md).
CI runs ImageBuilder → optional QEMU smoke → CMS-sign the `.img.gz` with
the same YubiKey-rooted PKI as `rasputin-os` → publish to GitHub Releases.

Known scaffold-stage shortcuts (all flagged for follow-up):

- **Agent delivery is overlay-based, not a feed.** Today the binary lands
  in the image via `files/usr/bin/rasputin-agent` + `files/etc/init.d/rasputin-agent`
  + `files/etc/uci-defaults/99-rasputin`. The design ([firewall-image.md §3](https://github.com/geekdojo/geekdojo-wiki/blob/main/projects/rasputin/design/os-images/firewall-image.md))
  is a custom usign-signed feed exposing `rasputin-agent` as a real
  package (`.apk`/`.ipk`). Overlay is acceptable for v1 scaffold; feed
  comes when we wire OTA updates from the controlplane.
- **WAN/LAN port assignment defaults to eth0=WAN / eth1=LAN.** Real Node N
  chassis labeling may differ; `uci-defaults/99-rasputin` is the place to
  flip if needed.
- **Suricata is installed but not enabled.** Tap-mode IDS configuration
  needs a real WAN tap; default-off keeps boot clean.
- **No A/B sysupgrade.** Bad image = re-flash via USB. Documented v1
  limitation ([firewall-image.md §5](https://github.com/geekdojo/geekdojo-wiki/blob/main/projects/rasputin/design/os-images/firewall-image.md)).

## Layout

```
README.md
.gitignore
.github/workflows/release.yml         (validate → build → smoke → sign → release)
scripts/init-imagebuilder.sh          (download + verify pinned OpenWrt ImageBuilder)
packages.txt                          (the list passed to `make image PACKAGES=...`)
files/                                (overlay applied to every image)
├── etc/
│   ├── rasputin/
│   │   ├── seed.env.template         (firewall provisioning seed)
│   │   ├── trust/                    (root-ca.pem injected by CI from org var)
│   │   └── README.md
│   ├── init.d/rasputin-agent         (procd service)
│   └── uci-defaults/99-rasputin      (one-shot first-boot UCI seed)
└── usr/
    ├── bin/                          (rasputin-agent dropped here by CI)
    └── lib/rasputin/                 (helpers)
```

`files/usr/bin/rasputin-agent` is **not committed** — it's authenticated-
fetched in CI from the latest `rasputin-control-plane` release (same
pattern as `rasputin-os`'s package `.mk`s).

## Quick start (dev)

> **Host OS:** ImageBuilder needs Linux. On a Mac, build inside a Linux
> VM/container, or use the CI loop (`gh workflow run release.yml -f full_build=true`).
> CI is fast for this repo — ~5–10 min per build, not hours like Buildroot.

```sh
git clone https://github.com/geekdojo/rasputin-openwrt-firewall
cd rasputin-openwrt-firewall
./scripts/init-imagebuilder.sh        # downloads pinned OpenWrt ImageBuilder

# Authenticated fetch of the agent (private repo):
mkdir -p files/usr/bin
gh release download v0.1.0 \
  --repo geekdojo/rasputin-control-plane \
  --pattern 'rasputin-agent-0.1.0-linux-amd64.tar.gz' \
  --dir /tmp
tar -xzf /tmp/rasputin-agent-0.1.0-linux-amd64.tar.gz -C files/usr/bin
chmod +x files/usr/bin/rasputin-agent

# Build the firewall image:
cd imagebuilder
make image PROFILE=generic \
  PACKAGES="$(tr '\n' ' ' < ../packages.txt)" \
  FILES="$(realpath ../files)" \
  EXTRA_IMAGE_NAME=rasputin

# Output: bin/targets/x86/64/openwrt-*-rasputin-*-combined-efi.img.gz
```

## Provisioning a flashed node

Mount the image's root partition (or the EFI partition for early-stage
provisioning) and edit `/etc/rasputin/seed.env`:

```sh
RASPUTIN_NODE_ROLE=firewall
RASPUTIN_NATS_URL=nats://cp-1.rasputin.tailnet:4222
RASPUTIN_CP_JOIN_TOKEN=...
```

The `99-rasputin` uci-defaults script reads this on first boot, writes
`/etc/config/rasputin`, configures WAN/LAN, enables the agent, and
self-deletes. See [provisioning.md](https://github.com/geekdojo/geekdojo-wiki/blob/main/projects/rasputin/design/os-images/provisioning.md).

## Cutting a release

Same CalVer tag pattern as `rasputin-os` — `YYYY.MM.MICRO[-suffix]`. A
`-dev.N` suffix triggers a prerelease; bare CalVer is stable.

```sh
git tag -a 2026.06.0-dev.1 -m "first scaffold cut"
git push origin 2026.06.0-dev.1
# → build → smoke-fw → sign-and-release → GitHub Release with
#   .img.gz + .img.gz.sig + manifest.json (compatible=rasputin-fw-n100)
```

## License

GPL-2.0 (matches OpenWrt's licensing — the image is a derivative work).
