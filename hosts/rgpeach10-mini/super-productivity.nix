# Super Productivity + its MCP server, self-hosted on mini.
#
# Three pieces are wired up here:
#
#   1. super-productivity   — the web app, built from the ryanpeach-homelab
#                             fork and served *privately* over the tailnet via
#                             `tailscale serve` (HTTPS, tailnet-only).
#   2. mcp-auth-proxy       — an OAuth 2.1 gateway, built from the fork. It
#                             wraps the stdio MCP server below and exposes it as
#                             an authenticated HTTPS `/mcp` endpoint.
#   3. Super-Productivity-MCP — the stdio MCP server, launched by the proxy as a
#                             child process via `npx` (the proxy image ships
#                             node + npm, so this works inside the container).
#
# The proxy is published to the public internet with `tailscale funnel`, so
# GitHub OAuth (configured via the sops secret below) is what keeps it locked
# down. super-productivity itself is never funnelled — it stays on the tailnet.
#
# Why podman (not the docker engine that hosts/rgpeach10-mini/default.nix
# enables): that docker daemon is deliberately `enableOnBoot = false` for the
# devcontainer workflow, so containers started under it would not survive a
# reboot. podman needs no long-running daemon — each container is a plain
# systemd unit — so these services come back cleanly on boot, independently of
# docker.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Host-side ports the containers publish on loopback only (never on the LAN;
  # tailscale serve/funnel are the only things that reach them).
  spPort = 3210; # super-productivity web  (container :80)
  proxyPort = 9000; # mcp-auth-proxy          (container :80)

  # tailscale serve/funnel HTTPS ports. The mini already runs `tailscale serve`
  # for ollama on 443 (see default.nix), and a node shares one set of serve
  # ports — so super-productivity's private serve uses 10000 and the public MCP
  # funnel uses 8443 (both valid Funnel ports; the trio is 443/8443/10000).
  serveHttpsPort = 10000;
  funnelHttpsPort = 8443;

  # super-productivity is pulled from Docker Hub, where the fork's CI publishes
  # it. mcp-auth-proxy has no published image yet, so it's still built on-host
  # from the fork (the `localhost/` prefix marks it local-only — podman won't
  # try to pull it).
  spImage = "docker.io/rgpeach10/super-productivity:latest";
  proxyImage = "localhost/mcp-auth-proxy:latest";

  ts = "${config.services.tailscale.package}/bin/tailscale";
  jq = "${pkgs.jq}/bin/jq";
  podman = "${pkgs.podman}/bin/podman";
  git = "${pkgs.git}/bin/git";

  # Pull $image (built + published by the source repo's own CI) and drop any
  # stale container of $name so ExecStart can recreate it. If the pull fails but
  # the image is already present, we keep it so a transient network blip at boot
  # doesn't take the service down.
  pullImage = image: name: ''
    set -u
    if ! ${podman} pull "${image}"; then
      echo "pull of ${image} failed; falling back to existing image if present" >&2
      ${podman} image exists "${image}"
    fi
    ${podman} rm -f "${name}" || true
  '';

  # Clone (or update) a GitHub repo at $src and `podman build` it into $tag,
  # then drop any stale container of $name so ExecStart can recreate it. If the
  # fetch/build fails but an image already exists, we keep the old image so a
  # transient network blip at boot doesn't take the service down.
  buildFromGit = repo: src: tag: name: ''
    set -u
    build() {
      if [ ! -d "${src}/.git" ]; then
        ${git} clone --depth 1 "${repo}" "${src}"
      else
        ${git} -C "${src}" fetch --depth 1 origin
        ${git} -C "${src}" reset --hard FETCH_HEAD
      fi
      ${podman} build -t "${tag}" "${src}"
    }
    if ! build; then
      echo "build of ${tag} failed; falling back to existing image if present" >&2
      ${podman} image exists "${tag}"
    fi
    ${podman} rm -f "${name}" || true
  '';

  # Block until tailscaled is up and the node is logged in (has a MagicDNS
  # name), so serve/funnel/external-url don't race tailscaled at boot.
  waitForTailscale = ''
    until ${ts} status --json | ${jq} -e '.Self.DNSName != ""' >/dev/null 2>&1; do
      echo "waiting for tailscale to come up..." >&2
      sleep 2
    done
  '';

  # ExecStart wrapper for the proxy. EXTERNAL_URL is derived at *runtime* from
  # this node's MagicDNS name (so the tailnet is never hard-coded) — it can't
  # come from an EnvironmentFile because systemd evaluates those before the
  # build/wait in preStart has run. The GitHub OAuth vars do come from the sops
  # EnvironmentFile and are passed through with bare `-e NAME`.
  proxyStart = pkgs.writeShellScript "mcp-auth-proxy-start" ''
    set -u
    mkdir -p /var/lib/mcp-auth-proxy/data
    ${waitForTailscale}
    dnsname=$(${ts} status --json | ${jq} -r '.Self.DNSName | rtrimstr(".")')
    ext="https://$dnsname:${toString funnelHttpsPort}"
    echo "mcp-auth-proxy external URL: $ext" >&2

    # --listen :80   : serve plain HTTP inside the container
    # --no-auto-tls  : funnel terminates TLS, so don't provision Let's Encrypt
    # -- npx ...     : the stdio MCP server the proxy authenticates in front of
    exec ${podman} run --rm --name mcp-auth-proxy \
      -p 127.0.0.1:${toString proxyPort}:80 \
      -v /var/lib/mcp-auth-proxy/data:/data \
      -e DATA_PATH=/data \
      -e SP_MCP_DATA_DIR=/data/super-productivity \
      -e EXTERNAL_URL="$ext" \
      -e GITHUB_CLIENT_ID \
      -e GITHUB_CLIENT_SECRET \
      -e GITHUB_ALLOWED_USERS \
      ${proxyImage} \
      --listen :80 --no-auto-tls \
      -- npx -y github:ryanpeach-homelab/Super-Productivity-MCP
  '';

  spStart = pkgs.writeShellScript "super-productivity-start" ''
    set -u
    exec ${podman} run --rm --name super-productivity \
      -p 127.0.0.1:${toString spPort}:80 \
      ${spImage}
  '';

  # The encrypted per-host secrets file is created by the operator out-of-band
  # (see the note at the bottom of this file). It lives under hosts/<host>/ to
  # match the `path_regex: hosts/rgpeach10-mini` rule in .sops.yaml. Only wire up
  # the sops secret once it exists, so CI — which has no such file and never
  # decrypts — still builds.
  secretsFile = ./secrets.yaml;
  haveSecrets = builtins.pathExists secretsFile;
in
{
  # podman as a daemonless container runtime for the long-running services.
  virtualisation.podman.enable = true;

  # serve/funnel terminate TLS on these ports on the tailscale0 interface, so
  # the firewall has to let them through there (the same reason default.nix
  # opens 443 for the ollama serve; this option is list-valued, so the two
  # definitions merge). Funnel ingress also lands on tailscale0.
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [
    funnelHttpsPort
    serveHttpsPort
  ];

  # GitHub OAuth credentials for the proxy, decrypted to
  # /run/secrets/mcp-auth-proxy-env as a systemd EnvironmentFile (dotenv:
  # GITHUB_CLIENT_ID=..., GITHUB_CLIENT_SECRET=..., GITHUB_ALLOWED_USERS=...).
  sops.secrets = lib.mkIf haveSecrets {
    "mcp-auth-proxy-env" = {
      sopsFile = secretsFile;
      # Default render path is /run/secrets/mcp-auth-proxy-env, referenced below.
    };
  };

  # All four units live under a single `systemd.services` attrset (statix flags
  # repeated top-level `systemd.services.<name>` keys).
  systemd.services = {
    # --- super-productivity (private, tailnet-only) -------------------------
    super-productivity = {
      description = "Super Productivity web app (Docker Hub image, run via podman)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      preStart = pullImage spImage "super-productivity";

      serviceConfig = {
        TimeoutStartSec = "10min"; # allow time for the image pull
        Restart = "on-failure";
        RestartSec = "10s";
        ExecStart = spStart;
        ExecStop = "${podman} stop -t 10 super-productivity";
      };
    };

    # --- mcp-auth-proxy + Super-Productivity-MCP (public via funnel) --------
    mcp-auth-proxy = {
      description = "mcp-auth-proxy wrapping Super-Productivity-MCP (built from fork)";
      wantedBy = [ "multi-user.target" ];
      # tailscaled-set applies `--hostname=ollama` (default.nix); wait for it so
      # the MagicDNS name is settled before proxyStart derives EXTERNAL_URL.
      after = [
        "network-online.target"
        "tailscaled.service"
        "tailscaled-set.service"
      ];
      wants = [
        "network-online.target"
        "tailscaled.service"
        "tailscaled-set.service"
      ];

      preStart = buildFromGit "https://github.com/ryanpeach-homelab/mcp-auth-proxy" "/var/lib/mcp-auth-proxy/src" proxyImage "mcp-auth-proxy";

      serviceConfig = {
        StateDirectory = "mcp-auth-proxy";
        TimeoutStartSec = "30min";
        Restart = "on-failure";
        RestartSec = "10s";
        # GitHub OAuth client id/secret + allowed users. Optional (`-`) so the
        # unit still builds/starts before the secret is provided; the proxy
        # just won't authenticate anyone useful until it exists.
        EnvironmentFile = [ "-/run/secrets/mcp-auth-proxy-env" ];
        ExecStart = proxyStart;
        ExecStop = "${podman} stop -t 10 mcp-auth-proxy";
      };
    };

    # --- tailscale serve: super-productivity, tailnet-only -----------------
    ts-serve-super-productivity = {
      description = "Expose super-productivity privately over the tailnet (tailscale serve)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "tailscaled.service"
        "tailscaled-set.service"
        "super-productivity.service"
      ];
      wants = [
        "tailscaled.service"
        "tailscaled-set.service"
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ${waitForTailscale}
        ${ts} serve --bg --https=${toString serveHttpsPort} http://127.0.0.1:${toString spPort}
      '';
      preStop = "${ts} serve --https=${toString serveHttpsPort} off || true";
    };

    # --- tailscale funnel: mcp-auth-proxy, public internet -----------------
    # Prerequisites on the tailnet (one-time, in the admin console): HTTPS
    # certificates + MagicDNS enabled, and Funnel allowed for this node in the
    # ACL policy (the `nodeAttrs` / `funnel` attribute).
    ts-funnel-mcp-auth-proxy = {
      description = "Expose mcp-auth-proxy to the public internet (tailscale funnel)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "tailscaled.service"
        "tailscaled-set.service"
        "mcp-auth-proxy.service"
      ];
      wants = [
        "tailscaled.service"
        "tailscaled-set.service"
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ${waitForTailscale}
        ${ts} funnel --bg --https=${toString funnelHttpsPort} http://127.0.0.1:${toString proxyPort}
      '';
      preStop = "${ts} funnel --https=${toString funnelHttpsPort} off || true";
    };
  };
}
