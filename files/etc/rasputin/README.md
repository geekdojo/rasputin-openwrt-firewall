# /etc/rasputin/

Per-image Rasputin runtime config.

| File | Source | Description |
|---|---|---|
| `seed.env` | written from `seed.env.template` by post-flash provisioning | Per-deployment provisioning seed (NATS URL + join token + role). Read once by `uci-defaults/99-rasputin` on first boot, which writes `/etc/config/rasputin` from it and then self-deletes. |
| `trust/root-ca.pem` | CI-injected from the geekdojo org variable `RASPUTIN_ROOT_CA_PEM` | Public root CA cert used by `rasputin-agent` to verify signed `.img.gz` update signatures (and any other signed-by-Rasputin artifacts) before invoking `sysupgrade`. YubiKey-backed (the private key lives on a YubiKey in Bryce's vault; see `os-images/release-pipeline.md §1`). |
