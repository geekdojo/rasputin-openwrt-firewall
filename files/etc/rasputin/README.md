# /etc/rasputin/

Per-image Rasputin runtime config.

| File | Source | Description |
|---|---|---|
| `seed.env` | written from `seed.env.template` by post-flash provisioning | Per-deployment provisioning seed (NATS URL + join token + role). Read once by `uci-defaults/99-rasputin` on first boot, which writes `/etc/config/rasputin` from it and then self-deletes. |
| `trust/root-ca.pem` | CI-injected from the geekdojo org variable `RASPUTIN_ROOT_CA_PEM` | Public root CA cert used by `rasputin-agent` to verify signed `.img.gz` update signatures (and any other signed-by-Rasputin artifacts) before invoking `sysupgrade`. YubiKey-backed (the private key lives on a YubiKey in Bryce's vault; see `os-images/release-pipeline.md §1`). |
| `agent-state/` | created at runtime by `rasputin-agent` | Agent state dir (`RASPUTIN_AGENT_STATE_DIR`, set by `init.d/rasputin-agent`): updater pending/health-check bookkeeping plus any mock-backend state. Lives here (not `/var`, which is tmpfs) so it survives reboots, and is covered by the sysupgrade keep-list like the rest of `/etc/rasputin/`. |
