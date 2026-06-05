# Super Productivity + its MCP server, self-hosted on mini.
#
# Three pieces are wired up here:
#
#   1. super-productivity   — the web app (Docker Hub image rgpeach10/…), served
#                             *privately* over the tailnet via `tailscale serve`
#                             (HTTPS, tailnet-only).
#   2. mcp-auth-proxy       — an OAuth 2.1 gateway (upstream ghcr.io/sigbit/…).
#                             It wraps the stdio MCP server below and exposes it
#                             as an authenticated HTTPS `/mcp` endpoint.
#   3. SP-MCP (organicmoron) — a single-file Python stdio MCP server, launched by
#                             the proxy as a child process (the proxy image ships
#                             python3 + pip, so this works inside the container).
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

  # Both images are pulled from registries (not built on-host): super-productivity
  # from Docker Hub (the fork's CI publishes it) and mcp-auth-proxy from upstream's
  # GitHub Container Registry. The proxy image is debian-slim with python3/pip (and
  # node) baked in, so it can launch the Python SP-MCP server inside the container.
  spImage = "docker.io/rgpeach10/super-productivity:latest";
  proxyImage = "ghcr.io/sigbit/mcp-auth-proxy:latest";

  ts = "${config.services.tailscale.package}/bin/tailscale";
  jq = "${pkgs.jq}/bin/jq";
  podman = "${pkgs.podman}/bin/podman";

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

  # Block until tailscaled is up and the node is logged in (has a MagicDNS
  # name), so serve/funnel/external-url don't race tailscaled at boot.
  waitForTailscale = ''
    until ${ts} status --json | ${jq} -e '.Self.DNSName != ""' >/dev/null 2>&1; do
      echo "waiting for tailscale to come up..." >&2
      sleep 2
    done
  '';

  # The MCP server the proxy wraps: organicmoron/SP-MCP, a single-file *Python*
  # stdio server (not an npm package). The sigbit proxy image already bundles
  # python3 / pip / curl, so this bootstrap — bind-mounted into the container and
  # run as the proxy's stdio child — installs the `mcp` SDK into the persistent
  # /data volume (once), fetches mcp_server.py, then execs it. XDG_DATA_HOME=/data
  # puts the server's plugin_commands/ + plugin_responses/ exchange dirs on the
  # volume too, so they survive container recreation.
  spMcpBootstrap = pkgs.writeShellScript "sp-mcp-bootstrap" ''
    set -eu
    d=/data/sp-mcp
    mkdir -p "$d/deps"
    if [ ! -e "$d/deps/mcp" ]; then
      pip3 install --quiet --break-system-packages --target="$d/deps" mcp
    fi
    curl -fsSL https://raw.githubusercontent.com/organicmoron/SP-MCP/main/mcp_server.py \
      -o "$d/mcp_server.py"
    exec env PYTHONPATH="$d/deps" XDG_DATA_HOME=/data python3 "$d/mcp_server.py"
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
    # -- sh ...      : the stdio MCP server the proxy authenticates in front of
    #                  (organicmoron/SP-MCP, bootstrapped by the script above)
    exec ${podman} run --rm --name mcp-auth-proxy \
      -p 127.0.0.1:${toString proxyPort}:80 \
      -v /var/lib/mcp-auth-proxy/data:/data \
      -v ${spMcpBootstrap}:/usr/local/bin/sp-mcp-bootstrap:ro \
      -e DATA_PATH=/data \
      -e EXTERNAL_URL="$ext" \
      -e GITHUB_CLIENT_ID \
      -e GITHUB_CLIENT_SECRET \
      -e GITHUB_ALLOWED_USERS \
      ${proxyImage} \
      --listen :80 --no-auto-tls \
      -- sh /usr/local/bin/sp-mcp-bootstrap
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

    # --- mcp-auth-proxy + SP-MCP (public via funnel) -----------------------
    mcp-auth-proxy = {
      description = "mcp-auth-proxy (upstream image) wrapping organicmoron/SP-MCP";
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

      preStart = pullImage proxyImage "mcp-auth-proxy";

      serviceConfig = {
        StateDirectory = "mcp-auth-proxy";
        TimeoutStartSec = "10min"; # allow time for the image pull
        Restart = "on-failure";
        RestartSec = "10s";
        # GitHub OAuth client id/secret + allowed users. Optional (`-`) so the
        # unit still starts before the secret is provided; the proxy just won't
        # authenticate anyone useful until it exists.
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
