# rasputin-openwrt-firewall — agent instructions

OpenWrt-based dedicated firewall image for [Rasputin](https://rasputin.geekdojo.com)
(Intel N100 / x86-64 only). Alpha, AGPL-3.0.

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
  `releases/latest/download/manifest.json`, which is itself signed — verify
  `manifest.json.sig` the same way before trusting a sha256 out of it. Releases
  cut before 2026-09 have no `manifest.json.sig`.
- The image is built with the OpenWrt ImageBuilder in CI. A rebuild is rarely
  content-free — the rolling upstream feed ships package/CVE changes even with zero repo
  commits.
- The seed file goes on the FAT volume labeled `RASPUTIN-FW` (not `RASPUTIN-OS`); see
  the README for the firewall seed reference.
- A commit or PR that fixes a tracked issue must use a **closing keyword** —
  `Fixes #N` / `Closes #N` — not a bare `(#N)` reference. Bare references leave the
  issue open after the fix ships (audited 2026-07-20: four of six stale-open issues
  across the rasputin repos were exactly this).

## Engineering standard

This repo follows the [Geekdojo development principles](https://github.com/geekdojo/geekdojo-brain/blob/main/engineering/development-principles.md), the architecture and coding standard for every Geekdojo product (Decided 2026-09-28). Read it before you plan or write code. Plans and code are reviewed against it, and review findings cite its rule IDs (for example `ARCH-IOC`).

- **It applies to all new code.** Legacy code is refactored toward it when a change can reasonably do so.
- **A departure needs an approved exception.** The process is in [Standard exceptions](https://github.com/geekdojo/geekdojo-brain/blob/main/engineering/standard-exceptions.md). Approved exceptions for this repo are listed in `EXCEPTIONS.md` at the repo root. The file is created when the first one is approved.
