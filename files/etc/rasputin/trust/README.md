# /etc/rasputin/trust/

CI injects `root-ca.pem` into this directory from the geekdojo org variable
`RASPUTIN_ROOT_CA_PEM` during the build job. The PEM file is gitignored
(`.gitignore` excludes `root-ca.pem`) so it never lives in the repo.

The `rasputin-agent` reads this cert to verify the detached CMS signature
on every signed `.img.gz` it's asked to install before invoking `sysupgrade`.
The root CA is YubiKey-backed; see `os-images/release-pipeline.md §1`.

This README is committed only to make the directory tracked.
