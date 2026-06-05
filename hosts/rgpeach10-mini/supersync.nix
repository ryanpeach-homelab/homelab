# SuperSync — Super Productivity's self-hosted sync server, on mini.
#
# SuperSync is *not* a flat-file/WebDAV server: it implements Super Productivity's
# operation-based (event-sourcing) sync protocol, persisted in **PostgreSQL** via
# Prisma. So this stack is three containers on a shared podman network:
#
#   1. supersync-postgres — postgres:16-alpine. The real data lives here.
#   2. supersync-server    — ghcr.io/super-productivity/supersync (official image),
#                            listens on :1900, talks to postgres.
#   3. ts-sync             — a Tailscale Funnel sidecar (see ts-funnel.nix) that
#                            publishes the server at https://sync.<tailnet>.ts.net
#                            (:443, public). This replaces the Caddy box from
#                            upstream's compose — Tailscale terminates TLS.
#
# Data persistence: the operator asked for the data to live on the NAS at
# /volume1/super-productivity. Postgres' data dir is bind-mounted there (and the
# server's /app/data alongside it). See the NFS mount + operator notes below.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  funnel = import ./ts-funnel.nix { inherit pkgs; };

  # --- knobs (swap-in-one-place) -------------------------------------------
  network = "supersync";
  pgImage = "docker.io/postgres:16-alpine";
  # Official, publicly pullable image (community alternatives: iari/supersync,
  # 43ntropy/supersync — swap here if you'd rather not track latest).
  syncImage = "ghcr.io/super-productivity/supersync:latest";
  syncPort = 1900;

  # Where the NAS share is mounted on the mini, and the dirs we bind into the
  # containers. The Synology shared folder `super-productivity` (NFS-exported)
  # lands here; see `fileSystems` + the operator note at the bottom.
  nasRoot = "/mnt/nas/super-productivity";
  pgData = "${nasRoot}/pgdata"; # -> postgres /var/lib/postgresql/data
  appData = "${nasRoot}/app-data"; # -> supersync /app/data

  ts = "${config.services.tailscale.package}/bin/tailscale";
  jq = "${pkgs.jq}/bin/jq";
  podman = "${pkgs.podman}/bin/podman";

  pullImage = image: name: ''
    set -u
    if ! ${podman} pull "${image}"; then
      echo "pull of ${image} failed; falling back to existing image if present" >&2
      ${podman} image exists "${image}"
    fi
    ${podman} rm -f "${name}" || true
  '';

  # Derive the tailnet's DNS suffix from the *host* node's MagicDNS name (e.g.
  # `ollama.tailnet.ts.net` -> `tailnet.ts.net`), so PUBLIC_URL / WebAuthn / CORS
  # never hard-code the tailnet. The host tailscaled is up regardless of the
  # sidecar, so we can read it here on the host before launching the container.
  waitForTailscale = ''
    until ${ts} status --json | ${jq} -e '.Self.DNSName != ""' >/dev/null 2>&1; do
      echo "waiting for tailscale to come up..." >&2
      sleep 2
    done
  '';

  secretsFile = ./secrets.yaml;
  haveSecrets = builtins.pathExists secretsFile;
in
{
  virtualisation.podman.enable = true;

  # --- NAS mount (NFS) ------------------------------------------------------
  # Mount the Synology `super-productivity` share so Postgres' data dir lives on
  # the NAS. `x-systemd.automount` + `nofail` mean it mounts lazily on first
  # access and a NAS outage/blip never wedges the mini's boot (a plain
  # `fileSystems` entry is required-at-boot by default, which would). Postgres is
  # ordered behind the automount via RequiresMountsFor below.
  #
  # NFS (not SMB) on purpose: Postgres over SMB/CIFS risks DB corruption from
  # broken file locking. To point elsewhere, change `device` to an IP/tailnet
  # name (e.g. `100.x.y.z:/volume1/super-productivity`) — robust if mDNS is flaky.
  fileSystems.${nasRoot} = {
    device = "nas.local:/volume1/super-productivity";
    fsType = "nfs";
    options = [
      "nfsvers=4"
      "x-systemd.automount"
      "noauto"
      "nofail"
      "x-systemd.idle-timeout=600"
      "x-systemd.mount-timeout=30"
    ];
  };

  # Resolve `nas.local` (Synology mDNS) from the mini. Swap the mount `device`
  # for a static IP/tailnet name if you'd rather not depend on mDNS at boot.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  # JWT signing secret + Postgres password, decrypted to /run/secrets/supersync-env
  # as a dotenv EnvironmentFile (JWT_SECRET=..., POSTGRES_PASSWORD=...). The
  # tailscale-authkey secret (shared with the mcp sidecar) is also declared here.
  sops.secrets = lib.mkIf haveSecrets {
    "supersync-env".sopsFile = secretsFile;
    "tailscale-authkey".sopsFile = secretsFile;
  };

  systemd.services = {
    # --- podman network + Funnel sidecar (sync.<tailnet>.ts.net:443) --------
    "podman-network-${network}" = funnel.mkNetworkUnit network;
    ts-sync = funnel.mkSidecarUnit {
      hostname = "sync";
      inherit network;
      target = "http://supersync-server:${toString syncPort}";
      extraAfter = [ "supersync-server.service" ];
    };

    # --- PostgreSQL ---------------------------------------------------------
    supersync-postgres = {
      description = "PostgreSQL for SuperSync (podman, data on the NAS)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "podman-network-${network}.service"
      ];
      wants = [ "network-online.target" ];
      requires = [ "podman-network-${network}.service" ];
      # Trigger/await the NAS automount before Postgres touches its data dir, so
      # it never initdb's into an empty local dir while the NAS is unmounted.
      unitConfig.RequiresMountsFor = nasRoot;

      preStart = ''
        ${pullImage pgImage "supersync-postgres"}
        mkdir -p ${pgData}
      '';

      serviceConfig = {
        TimeoutStartSec = "10min";
        Restart = "on-failure";
        RestartSec = "10s";
        # POSTGRES_PASSWORD is forwarded from the sops EnvironmentFile.
        EnvironmentFile = [ "-/run/secrets/supersync-env" ];
        ExecStart = pkgs.writeShellScript "supersync-postgres-start" ''
          set -u
          exec ${podman} run --rm --name supersync-postgres \
            --network=${network} \
            -e POSTGRES_USER=supersync \
            -e POSTGRES_DB=supersync \
            -e POSTGRES_PASSWORD \
            -v ${pgData}:/var/lib/postgresql/data \
            ${pgImage}
        '';
        ExecStop = "${podman} stop -t 30 supersync-postgres";
      };
    };

    # --- SuperSync server ---------------------------------------------------
    supersync-server = {
      description = "SuperSync server (official image, public via Funnel sidecar)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "tailscaled.service"
        "tailscaled-set.service"
        "podman-network-${network}.service"
        "supersync-postgres.service"
      ];
      wants = [
        "network-online.target"
        "tailscaled.service"
        "tailscaled-set.service"
      ];
      requires = [
        "podman-network-${network}.service"
        "supersync-postgres.service"
      ];
      unitConfig.RequiresMountsFor = nasRoot;

      preStart = ''
        ${pullImage syncImage "supersync-server"}
        mkdir -p ${appData}
        # Wait for Postgres to accept connections before the server runs its
        # startup migrations against it.
        until ${podman} exec supersync-postgres pg_isready -U supersync >/dev/null 2>&1; do
          echo "waiting for supersync-postgres to be ready..." >&2
          sleep 2
        done
      '';

      serviceConfig = {
        StateDirectory = "supersync";
        TimeoutStartSec = "10min";
        Restart = "on-failure";
        RestartSec = "10s";
        # JWT_SECRET + POSTGRES_PASSWORD from the sops EnvironmentFile.
        EnvironmentFile = [ "-/run/secrets/supersync-env" ];
        ExecStart = pkgs.writeShellScript "supersync-server-start" ''
          set -u
          ${waitForTailscale}
          suffix=$(${ts} status --json | ${jq} -r '.Self.DNSName | rtrimstr(".") | sub("^[^.]+\\.";"")')
          public="https://sync.$suffix"
          echo "supersync public URL: $public" >&2

          # DATABASE_URL embeds the password from the EnvironmentFile; use an
          # alphanumeric POSTGRES_PASSWORD to avoid URL-encoding surprises.
          # CORS must allow the SP clients: the self-hosted web app (served at
          # :10000 by super-productivity.nix) and the hosted app.
          exec ${podman} run --rm --name supersync-server \
            --network=${network} \
            -e NODE_ENV=production \
            -e PORT=${toString syncPort} \
            -e DATABASE_URL="postgresql://supersync:$POSTGRES_PASSWORD@supersync-postgres:5432/supersync" \
            -e JWT_SECRET \
            -e PUBLIC_URL="$public" \
            -e CORS_ORIGINS="https://ollama.$suffix:10000,https://app.super-productivity.com" \
            -e WEBAUTHN_RP_ID="sync.$suffix" \
            -e WEBAUTHN_RP_NAME="SuperSync" \
            -e WEBAUTHN_ORIGIN="$public" \
            -e RUN_MIGRATIONS_ON_STARTUP=true \
            -v ${appData}:/app/data \
            ${syncImage}
        '';
        ExecStop = "${podman} stop -t 10 supersync-server";
      };
    };
  };
}
# --- One-time operator setup (SuperSync) ------------------------------------
#
# 1. NAS (Synology): create a shared folder `super-productivity` and NFS-export
#    /volume1/super-productivity to the mini's IP (read/write). Because Postgres
#    runs as uid 70 (alpine) inside the container, the export must let that uid
#    write — set the export's squash to "Map all users to admin" (or chown the
#    folder so uid 70 can write). NFSv4 is assumed (nfsvers=4 above).
#
# 2. Tailscale: see ts-funnel.nix — enable MagicDNS + HTTPS certs, allow Funnel
#    for the sidecar's tag, and store the auth key as the `tailscale-authkey`
#    sops secret.
#
# 3. Secrets — add to hosts/rgpeach10-mini/secrets.yaml (sops):
#      supersync-env: |
#        JWT_SECRET=<32+ random chars>
#        POSTGRES_PASSWORD=<alphanumeric password>
#      tailscale-authkey: |
#        TS_AUTHKEY=tskey-auth-...
#
# 4. In the Super Productivity client, point Sync at https://sync.<tailnet>.ts.net
#    and register an account (first user). WebAuthn/passkeys are bound to that
#    origin, so use the funnel URL consistently.
