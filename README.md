# homelab

NixOS configurations for my homelab, managed as a single flake. Hosts pull
their configuration from this repo via a GitOps, **pull-after-CI** workflow:

1. You open a PR with a change.
2. CI builds **every host's** system closure (`.github/workflows/build.yml`).
   The PR can only merge once those builds pass.
3. On merge to `main`, each host's `system.autoUpgrade` timer pulls the repo
   and rebuilds itself from the locked flake — so every machine ends up running
   exactly the closure CI validated.

## Hosts

| Host             | Architecture    | Notes                          |
| ---------------- | --------------- | ------------------------------ |
| `rgpeach10-mini` | `x86_64-linux`  | mini PC, runs ollama (tailnet) |
| `rgpeach10-pi1`  | `aarch64-linux` | Raspberry Pi                   |

Hosts and their architectures are declared in `flake.nix` (the `hosts`
attribute set). Add a host by adding an entry there and a directory under
`hosts/`.

## Layout

```
flake.nix                     # nixosConfigurations + CI checks for every host
modules/common.nix            # shared config: nix, auto-upgrade, ssh, tailscale, user
hosts/<host>/default.nix      # per-host config
hosts/<host>/hardware-configuration.nix
.github/workflows/build.yml   # builds each host on PRs and main
scripts/                      # legacy imperative scripts (being migrated into nix)
```

## First-time setup

Run these once, locally, with Nix installed (`nix-command` + `flakes`):

```sh
# 1. Generate and commit the lock file so hosts pin the same inputs.
nix flake lock

# 2. Build a host locally to sanity-check (aarch64 needs emulation/binfmt).
nix build .#nixosConfigurations.rgpeach10-mini.config.system.build.toplevel
```

Then, **per host**:

1. On the real machine, generate its hardware config and replace the
   placeholder:
   ```sh
   nixos-generate-config --show-hardware-config \
     > hosts/<host>/hardware-configuration.nix
   ```
   The committed `hardware-configuration.nix` files are placeholders that only
   exist so CI can evaluate the closure — replace them before relying on a host.
2. Add your SSH public key under `users.users.rgpeach10.openssh.authorizedKeys`
   in `modules/common.nix`. Password auth is disabled, so do this **before** the
   first deploy or you'll lock yourself out.
3. Do the initial switch by hand (auto-upgrade takes over afterward):
   ```sh
   sudo nixos-rebuild switch --flake .#<host>          # on the host, or
   nixos-rebuild switch --flake .#<host> \             # remotely
     --target-host root@<host>.tailnet
   ```

## Enforcing the CI gate

Make the builds a required check so nothing merges untested:

> GitHub → repo **Settings → Branches → Branch protection rules** (or
> **Rulesets**) → protect `main` → require the
> `build rgpeach10-mini (x86_64-linux)` and `build rgpeach10-pi1 (aarch64-linux)`
> status checks to pass before merging.

## Auto-upgrade behavior

Configured in `modules/common.nix` (`system.autoUpgrade`):

- Pulls `github:ryanpeach-homelab/homelab#<hostname>` daily at ~04:00
  (+ randomized delay).
- Uses the repo's committed `flake.lock` (no input re-resolution), so upgrades
  are reproducible.
- `allowReboot = false` by default — kernel/initrd changes apply on the next
  manual reboot. Flip it on with a reboot window if you want that automated.
