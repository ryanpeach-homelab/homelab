# Secrets (sops-nix)

Encrypted secrets live here. Files are encrypted with [sops](https://github.com/getsops/sops)
using age recipients, and decrypted on each host by sops-nix at activation time.

## How decryption works

Each host decrypts using an age key **derived from its SSH ed25519 host key**
(`sops.age.sshKeyPaths` in `modules/common.nix`), so there is no extra private
key to copy onto the machine — if the host can SSH, it can decrypt.

## One-time setup

1. Enter the dev shell (provides `sops`, `age`, `ssh-to-age`):
   ```sh
   nix develop
   ```
2. Create your personal admin age key and note the `age1...` public key:
   ```sh
   mkdir -p ~/.config/sops/age
   age-keygen -o ~/.config/sops/age/keys.txt
   ```
3. Get each host's age recipient from its SSH ed25519 **public** host key:
   ```sh
   ssh-keyscan rgpeach10-mini 2>/dev/null | ssh-to-age
   ssh-keyscan rgpeach10-pi1  2>/dev/null | ssh-to-age
   ```
4. Put the resulting `age1...` recipients into `../.sops.yaml`, replacing the
   placeholders for `admin`, `mini`, and `pi1`.

## Creating / editing a secret

```sh
sops secrets/common.yaml          # all hosts
sops secrets/rgpeach10-mini.yaml  # mini only
```

`.sops.yaml`'s `creation_rules` decide which recipients each file is encrypted
for, so encryption "just works" based on the file path.

## Consuming a secret on a host

In a host module (or `modules/common.nix`):

```nix
sops.defaultSopsFile = ../secrets/common.yaml;
sops.secrets."example-token" = { };          # -> /run/secrets/example-token
# sops.secrets."svc-password".owner = "svc";  # restrict ownership
```

Reference the decrypted path (e.g. `config.sops.secrets."example-token".path`)
from the service that needs it.
