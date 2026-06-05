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

| Host             | Architecture    | Notes                                                  |
| ---------------- | --------------- | ------------------------------------------------------ |
| `rgpeach10-mini` | `x86_64-linux`  | mini PC — ollama + Super Productivity stack (tailnet)  |
| `rgpeach10-pi1`  | `aarch64-linux` | Raspberry Pi                                           |

Hosts and their architectures are declared in `flake.nix` (the `hosts`
attribute set). Add a host by adding an entry there and a directory under
`hosts/`.

## Layout

```
flake.nix                       # nixosConfigurations, CI checks, dev shell
modules/common.nix              # shared: nix, auto-upgrade, ssh, tailscale, sops, user
hosts/<host>/default.nix        # per-host config
hosts/<host>/hardware-configuration.nix
hosts/<host>/secrets.yaml       # sops-encrypted per-host secrets (optional)
.sops.yaml                      # sops creation rules (recipients per path)
.pre-commit-config.yaml         # gitleaks + statix + deadnix hooks
.github/workflows/build.yml     # builds + CVE-scans each host on PRs and main
.github/workflows/lint.yml      # runs the pre-commit hooks + full gitleaks scan
```

## Dev shell, linting & secret scanning

`nix develop` drops you into a shell with the secrets + lint tooling and
installs the git pre-commit hook automatically.

**Pre-commit** (`.pre-commit-config.yaml`, published upstream hooks only; also
run in CI by `lint.yml`):

- [`pre-commit/pre-commit-hooks`](https://github.com/pre-commit/pre-commit-hooks)
  — trailing whitespace, end-of-file, line endings, large files, etc.
- [`gitleaks`](https://github.com/gitleaks/gitleaks) — blocks commits containing
  secrets (scans staged changes).

**CI-only checks** (`lint.yml`, run directly — no paid actions):

- **statix** / **deadnix** — Nix anti-patterns and dead code (no published
  pre-commit hook, so they run in CI).
- **gitleaks detect** — full repo + history secret scan (the pre-commit hook
  only covers staged changes).

Each host build is also CVE-scanned with **vulnix** (non-blocking, reported on
the PR).

## Secrets

Managed with [sops-nix](https://github.com/Mic92/sops-nix); each host decrypts
using an age key derived from its SSH host key, and the admin via PGP. Per-host
secrets live at `hosts/<host>/secrets.yaml`; recipients per path are defined in
[`.sops.yaml`](.sops.yaml).

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

## Super Productivity stack (mini)

`hosts/rgpeach10-mini/super-productivity.nix` self-hosts three pieces, all as
podman containers/systemd units (podman is used rather than the host's docker
daemon, which is `enableOnBoot = false` for the devcontainer workflow):

| Piece                      | Source (built on host from fork) | Exposure                                            |
| -------------------------- | -------------------------------- | --------------------------------------------------- |
| `super-productivity` (web) | `ryanpeach-homelab/super-productivity` | `tailscale serve`, HTTPS **:10000**, tailnet-only |
| `mcp-auth-proxy`           | `ryanpeach-homelab/mcp-auth-proxy`     | `tailscale funnel`, HTTPS **:8443**, public      |
| `Super-Productivity-MCP`   | `ryanpeach-homelab/Super-Productivity-MCP` (via `npx github:`) | wrapped by the proxy as a stdio child |

The images are built **on the host** from the forks (`git clone` + `podman
build`) the first time each unit starts, so the box needs outbound access to
GitHub and npm. CI only builds the NixOS closure — it never runs podman — so the
on-host build cost doesn't affect the merge gate.

The proxy's public URL is derived at runtime from the node's MagicDNS name, so
the tailnet is never hard-coded. The mini advertises itself as `ollama`
(`default.nix`), so the funnel URL is `https://ollama.<tailnet>.ts.net:8443` and
the private web app is `https://ollama.<tailnet>.ts.net:10000`.

### One-time operator setup

1. **Tailnet** (admin console): enable **MagicDNS + HTTPS certificates**, and
   allow **Funnel** for the mini (advertised as `ollama`) in the ACL policy
   (`nodeAttrs` → `funnel`).
2. **GitHub OAuth app** (Settings → Developer settings → OAuth Apps):
   - Homepage URL: `https://ollama.<tailnet>.ts.net:8443`
   - Authorization callback URL: same origin (see the proxy logs on first start
     for the exact callback path it advertises).
   - Note the **Client ID** and generate a **Client secret**.
3. **Secret** — store the proxy's env as `mcp-auth-proxy-env` in the per-host
   sops file `hosts/rgpeach10-mini/secrets.yaml` (the path matches the
   `hosts/rgpeach10-mini` rule in `.sops.yaml`; the service loads it as an
   `EnvironmentFile`). Until this file exists the service still builds and
   starts, but won't authenticate anyone:
   ```sh
   sops hosts/rgpeach10-mini/secrets.yaml
   ```
   ```yaml
   mcp-auth-proxy-env: |
     GITHUB_CLIENT_ID=<client id>
     GITHUB_CLIENT_SECRET=<client secret>
     GITHUB_ALLOWED_USERS=<your-github-username>
   ```
   (Requires the mini's real age recipient in [`.sops.yaml`](.sops.yaml) — it's
   still a placeholder there until the host is reachable.)

> **Data caveat:** `Super-Productivity-MCP` reads task data from a local data
> directory that the Super Productivity *plugin* populates. That plugin runs in
> the **browser/desktop app**, not in the headless web container — so the
> server-side MCP instance does not automatically see the data you enter in the
> self-hosted web app. Hosting all three is wired up here; sharing live data
> between them is a separate concern (e.g. running the plugin against the
> server's `SP_MCP_DATA_DIR`, or a sync setup).

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
- **Also pulls + rebuilds ~2 min after every boot** (`OnBootSec` on the
  `nixos-upgrade` timer), so a reboot doubles as a "reimage": power-cycle a host
  and it converges on the latest locked flake on `main`.
- Uses the repo's committed `flake.lock` (no input re-resolution), so upgrades
  are reproducible.
- `allowReboot = false` by default — kernel/initrd changes apply on the next
  manual reboot. Flip it on with a reboot window if you want that automated.
