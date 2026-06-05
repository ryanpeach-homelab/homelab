# Reusable Tailscale "Funnel sidecar" for the mini.
#
# Background — why this exists. `tailscale serve`/`funnel` run by the *host*
# tailscaled are capped per node: Funnel may only use ports 443/8443/10000, and
# a node has exactly one of each. The host node (advertised as `ollama`) already
# spends them (ollama serve on 443, the SP web app serve on 10000). To publish
# *more* services we give each its own Tailscale **node** — a `tailscale`
# container that joins the tailnet under its own hostname and Funnels :443 to the
# service. The cap is per node, so N nodes = N public :443 endpoints with clean
# `name.<tailnet>.ts.net` URLs.
#
# How it works without disturbing the host tailscaled:
#   * The sidecar runs in **userspace networking mode** (`TS_USERSPACE=true`), so
#     it never creates a tailscale0 interface or touches the host netns — no
#     conflict with the system tailscaled, and no NET_ADMIN / /dev/net/tun.
#   * Funnel ingress arrives through Tailscale's relays into the sidecar's
#     userspace netstack, which proxies to the target per `TS_SERVE_CONFIG`. So
#     there is no host firewall port to open for these (unlike the host serve).
#   * The sidecar and the app share a **podman network**; the sidecar proxies to
#     the app by container name (e.g. http://supersync-server:1900) rather than
#     localhost, so each container stays an independent systemd unit.
#
# Operator prerequisites (one-time, Tailscale admin console):
#   * Enable MagicDNS + HTTPS certificates for the tailnet.
#   * Create a tag (e.g. `tag:funnel`) and grant it the `funnel` node attribute
#     in the ACL policy (`nodeAttrs`).
#   * Mint a **reusable + ephemeral** auth key tagged with it and store it as the
#     sops secret `tailscale-authkey` (dotenv: `TS_AUTHKEY=tskey-...`). Ephemeral
#     means dead sidecars are auto-removed from the device list; reusable means
#     every sidecar can register with the same key; the persisted state dir keeps
#     a restart from registering a *new* node.
{ pkgs }:
let
  podman = "${pkgs.podman}/bin/podman";
  # Pinned to the stable channel tag; the containerboot entrypoint reads the
  # TS_* env vars below and performs the ${TS_CERT_DOMAIN} substitution in the
  # serve config at runtime.
  tsImage = "ghcr.io/tailscale/tailscale:stable";
in
{
  # Idempotent oneshot that ensures a podman bridge network exists. The app
  # container(s) and the sidecar all attach to it and resolve each other by name.
  mkNetworkUnit = network: {
    description = "podman network ${network}";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = "${podman} network exists ${network} || ${podman} network create ${network}";
  };

  # A Tailscale Funnel sidecar: registers as tailnet node `hostname` and Funnels
  # public HTTPS :443 -> `target` (a URL reachable on `network`, e.g.
  # http://app:1900). `extraAfter` lets the caller order it behind the app unit.
  mkSidecarUnit =
    {
      hostname,
      network,
      target,
      extraAfter ? [ ],
    }:
    let
      # ${TS_CERT_DOMAIN} is substituted by the container at runtime with this
      # node's MagicDNS name, so the tailnet is never hard-coded here.
      serveConfig = pkgs.writeText "ts-serve-${hostname}.json" (
        builtins.toJSON {
          TCP."443".HTTPS = true;
          Web."\${TS_CERT_DOMAIN}:443".Handlers."/".Proxy = target;
          AllowFunnel."\${TS_CERT_DOMAIN}:443" = true;
        }
      );
    in
    {
      description = "tailscale Funnel sidecar: ${hostname} (:443 -> ${target})";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "podman-network-${network}.service"
      ] ++ extraAfter;
      wants = [
        "network-online.target"
        "podman-network-${network}.service"
      ];

      serviceConfig = {
        # Persist node identity so a restart reconnects as the same node instead
        # of registering a new one (which would burn a device slot until the
        # ephemeral reaper catches up). Creates /var/lib/tailscale-<hostname>.
        StateDirectory = "tailscale-${hostname}";
        # TS_AUTHKEY comes from the optional sops secret; bare `-e TS_AUTHKEY`
        # forwards it from the unit env. Optional (`-`) so the unit still starts
        # before the key is provisioned (it just can't join until it exists).
        EnvironmentFile = [ "-/run/secrets/tailscale-authkey" ];
        Restart = "on-failure";
        RestartSec = "10s";
        ExecStartPre = "-${podman} rm -f ts-${hostname}";
        ExecStart = pkgs.writeShellScript "ts-${hostname}-start" ''
          exec ${podman} run --rm --name ts-${hostname} \
            --network=${network} \
            -v /var/lib/tailscale-${hostname}:/var/lib/tailscale \
            -v ${serveConfig}:/config/serve.json:ro \
            -e TS_AUTHKEY \
            -e TS_HOSTNAME=${hostname} \
            -e TS_USERSPACE=true \
            -e TS_STATE_DIR=/var/lib/tailscale \
            -e TS_SERVE_CONFIG=/config/serve.json \
            ${tsImage}
        '';
        ExecStop = "${podman} stop -t 10 ts-${hostname}";
      };
    };
}
