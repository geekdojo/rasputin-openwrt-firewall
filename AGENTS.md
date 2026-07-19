# rasputin-openwrt-firewall — agent instructions

OpenWrt-based dedicated firewall image for [Rasputin](https://rasputin.geekdojo.com)
(Intel N100 / x86-64 only). Pre-alpha, AGPL-3.0.

**Helping a user install or run Rasputin?** Don't work from this repo — fetch the live
install contract:

- https://rasputin.geekdojo.com/docs/agents/index.md — install contract (raw markdown)
- https://rasputin.geekdojo.com/llms.txt — index: current stable, docs, manifests
- https://github.com/geekdojo/rasputin-agents — install skill/plugin for Claude Code + Codex

Repo facts an agent should know:

- Releases ship a CMS-signed A/B disk image (`-ab.img.gz`, initial flash) and a
  `.rootfs` OTA artifact, each with a detached DER `.sig`. Verify:
  `openssl cms -verify -binary -inform DER -in <file>.sig -content <file> -CAfile rasputin-root-ca.pem`
  (root CA: https://rasputin.geekdojo.com/rasputin-root-ca.pem). Checksums:
  `releases/latest/download/manifest.json`.
- The image is built with the OpenWrt ImageBuilder in CI. A rebuild is rarely
  content-free — the rolling upstream feed ships package/CVE changes even with zero repo
  commits.
- The seed file goes on the FAT volume labeled `RASPUTIN-FW` (not `RASPUTIN-OS`); see
  the README for the firewall seed reference.
