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

| Piece                      | Source                                 | Exposure                                            |
| -------------------------- | -------------------------------------- | --------------------------------------------------- |
| `super-productivity` (web) | Docker Hub `rgpeach10/super-productivity` (published by the fork's CI) | `tailscale serve`, HTTPS **:10000**, tailnet-only |
| `mcp-auth-proxy`           | GHCR `ghcr.io/sigbit/mcp-auth-proxy` (upstream) | Funnel sidecar, public at `https://mcp.<tailnet>.ts.net` (**:443**) |
| `SP-MCP` (Python)          | `organicmoron/SP-MCP` (fetched at runtime) | wrapped by the proxy as a stdio child |

Both container images are **pulled** from registries — `super-productivity`
from Docker Hub (the fork's CI publishes it) and `mcp-auth-proxy` from upstream's
GHCR. The proxy image also ships python3/pip, so it launches the Python MCP
server (`organicmoron/SP-MCP`) in-process: a small bootstrap installs the `mcp`
SDK into the data volume and fetches `mcp_server.py` at startup. The box needs
outbound access (Docker Hub / GHCR / GitHub raw / PyPI). CI here only builds the
NixOS closure — it never runs podman — so none of this affects the merge gate.

The private web app is served at `https://ollama.<tailnet>.ts.net:10000` (the
mini's host node advertises itself as `ollama`, see `default.nix`). The MCP proxy
is **public via its own Tailscale node** — see *Scaling public services* below.

## Scaling public services past Funnel's port limit (mini)

Tailscale **Funnel** is capped *per node*: only ports **443/8443/10000**, one of
each. The host node spends them on the ollama and SP-web serves, so publishing
more services that way doesn't scale. Instead, each public service gets **its own
Tailscale node** via a Funnel **sidecar container** (`ts-funnel.nix`):

- The sidecar (`ghcr.io/tailscale/tailscale`) joins the tailnet under its own
  hostname (`mcp`, `sync`, …) in **userspace mode** — no host `tailscale0`, so it
  never conflicts with the system tailscaled and needs no extra privileges.
- It shares a **podman network** with the app and Funnels `:443` → the app, so
  each service is reachable at a clean `https://<name>.<tailnet>.ts.net` (no port
  juggling). The free plan allows **100 devices**, so this scales fine.
- `mcp-auth-proxy` (node `mcp`) and SuperSync (node `sync`) both use this.

`ts-funnel.nix` exposes `mkNetworkUnit` + `mkSidecarUnit` so adding the next
public service is a few lines.

### One-time operator setup

1. **Tailnet** (admin console): enable **MagicDNS + HTTPS certificates**. Create
   a tag (e.g. `tag:funnel`) and grant it the `funnel` node attribute in the ACL
   policy (`nodeAttrs`), then mint a **reusable + ephemeral** auth key tagged with
   it. Store it as the `tailscale-authkey` sops secret (used by every Funnel
   sidecar — `mcp`, `sync`, …):
   ```yaml
   tailscale-authkey: |
     TS_AUTHKEY=tskey-auth-...
   ```
   (The host node `ollama` still also needs Funnel allowed if you keep using it.)
2. **GitHub OAuth app** (Settings → Developer settings → OAuth Apps):
   - Homepage URL: `https://mcp.<tailnet>.ts.net`
   - Authorization callback URL: same origin (see the proxy logs on first start
     for the exact callback path it advertises).
   - Note the **Client ID** and generate a **Client secret**.
   > Migrated from the old `ollama:8443` funnel: if you set this up before, the
   > proxy's origin changed to `https://mcp.<tailnet>.ts.net` — **update the OAuth
   > app's callback URL** or logins will fail.
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

> **Data caveat:** `SP-MCP` exchanges data with Super Productivity through
> file-based `plugin_commands/` + `plugin_responses/` dirs (under the container's
> `XDG_DATA_HOME=/data`) that its **plugin** writes. That plugin runs in the
> **browser/desktop app**, not in the headless web container — so the
> server-side MCP instance does not automatically see the data you enter in the
> self-hosted web app. Hosting all three is wired up here; sharing live data
> between them is a separate concern (e.g. pointing the plugin at the server's
> data dir, or a sync setup).

## SuperSync (mini)

`hosts/rgpeach10-mini/supersync.nix` self-hosts Super Productivity's official
sync server. SuperSync isn't WebDAV — it's an operation-based (event-sourcing)
protocol persisted in **PostgreSQL**, so the stack is three containers on a
shared podman network: `supersync-postgres` (`postgres:16-alpine`, the real
data), `supersync-server` (`ghcr.io/super-productivity/supersync`, **:1900**),
and a Funnel sidecar `ts-sync` publishing it at `https://sync.<tailnet>.ts.net`
(**:443**, public). The sidecar replaces upstream's Caddy box — Tailscale
terminates TLS.

**Data lives on the NAS.** The Synology `super-productivity` share is mounted on
the mini at `/mnt/nas/super-productivity` over **NFS** (with
`x-systemd.automount` + `nofail`, so a NAS blip never wedges boot), and Postgres'
data dir + the server's `/app/data` are bind-mounted there. NFS, not SMB:
Postgres over SMB risks DB corruption from broken file locking.

### One-time operator setup

1. **NAS** (Synology): create a shared folder `super-productivity` and
   **NFS-export** `/volume1/super-productivity` to the mini (read/write, NFSv4).
   Postgres runs as uid 70 inside the container, so the export must let that uid
   write — set squash to "Map all users to admin" (or chown the folder). To use
   an IP/tailnet name instead of `nas.local`, change `device` in `supersync.nix`.
2. **Tailscale**: same `tailscale-authkey` secret as above (the `sync` sidecar
   reuses it).
3. **Secret** — add to `hosts/rgpeach10-mini/secrets.yaml`:
   ```yaml
   supersync-env: |
     JWT_SECRET=<32+ random chars>
     POSTGRES_PASSWORD=<alphanumeric password>
   ```
   (Keep the password alphanumeric — it's embedded in `DATABASE_URL`.)
4. **Client**: point Super Productivity's Sync at `https://sync.<tailnet>.ts.net`
   and register the first account. Passkeys/WebAuthn bind to that origin, so use
   the funnel URL consistently.

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
