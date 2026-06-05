# rgpeach10-mini — x86_64 mini PC.
{ config, pkgs, ... }:
let
  # Use the same tailscale package the daemon runs, so the CLI matches.
  tailscale = config.services.tailscale.package;
in
{
  imports = [ ./hardware-configuration.nix ];

  # EFI / systemd-boot.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # --- ollama ---------------------------------------------------------------
  # ollama listens on localhost only and is reached over the tailnet through
  # `tailscale serve` (HTTPS, below) — never on the LAN. `loadModels` pulls the
  # listed models on activation so they are ready to use after a deploy.
  services.ollama = {
    enable = true;
    host = "127.0.0.1";
    port = 11434;
    loadModels = [
      "gemma4:26b" # Gemma 4 26B (MoE) — main chat / generation model.
      "embeddinggemma" # Gemma embedding model for RAG / vector search.
    ];
  };

  # --- MagicDNS name --------------------------------------------------------
  # Advertise this node to the tailnet as `ollama` (the OS hostname stays
  # `rgpeach10-mini` for the flake). MagicDNS then resolves it as
  # `ollama.<tailnet>.ts.net`, and `tailscale serve` issues its TLS cert for
  # that name. `tailscale set` is non-destructive (unlike `up`), so this only
  # changes the hostname and runs on every activation.
  services.tailscale.extraSetFlags = [ "--hostname=ollama" ];

  # --- Expose ollama on the tailnet via `tailscale serve` -------------------
  # Proxies https://ollama.<tailnet>.ts.net/ -> http://127.0.0.1:11434 so the
  # ollama API is reachable over HTTPS on the tailnet (with an automatic
  # Tailscale cert) and never on the LAN. Requires HTTPS certificates /
  # MagicDNS to be enabled for the tailnet in the admin console.
  systemd.services.tailscale-serve-ollama = {
    description = "tailscale serve: expose ollama over the tailnet (HTTPS 443 -> 11434)";
    after = [
      "tailscaled.service"
      "tailscaled-set.service"
      "ollama.service"
    ];
    wants = [
      "tailscaled.service"
      "tailscaled-set.service"
      "ollama.service"
    ];
    wantedBy = [ "multi-user.target" ];
    # Wait for the node to come up before (re)configuring serve, to avoid a
    # boot-time race with tailscaled bringing the tailnet connection up.
    script = ''
      until ${tailscale}/bin/tailscale status >/dev/null 2>&1; do sleep 2; done
      exec ${tailscale}/bin/tailscale serve --bg --https 443 http://127.0.0.1:11434
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStop = "${tailscale}/bin/tailscale serve --https 443 off";
    };
  };

  # tailscale serve terminates TLS on 443 on the tailscale0 interface.
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 443 ];

  # --- VSCode Remote-SSH + devcontainers ------------------------------------
  # Goal: SSH in from VSCode (over the tailnet) and "Reopen in Container",
  # including devcontainers that use the docker-in-docker feature.
  #
  # 1. Docker engine. The VSCode Dev Containers extension drives the host's
  #    Docker daemon to build/run the container; the docker-in-docker feature
  #    then runs a nested dockerd *inside* that container, which works because
  #    the standard daemon allows the privileged container it needs.
  #
  #    autoPrune periodically runs `docker system prune` to clear stopped
  #    containers and dangling images so leftovers don't pile up. Note: it
  #    only reaps *stopped* containers — a still-running one is untouched.
  #
  #    enableOnBoot = false keeps dockerd from starting at boot; it
  #    socket-activates the first time something uses the Docker socket (a
  #    `docker` command, or VSCode connecting). So nothing runs unless you're
  #    actively using it, and even `--restart=always` containers don't quietly
  #    come back after a reboot — the daemon isn't up to restart them.
  virtualisation.docker = {
    enable = true;
    enableOnBoot = false;
    autoPrune.enable = true;
  };

  # 2. nix-ld. The VSCode Remote-SSH "server" is a prebuilt, dynamically
  #    linked Node binary; on NixOS it won't start without a dynamic loader.
  #    nix-ld provides one so the server (and other downloaded binaries, like
  #    devcontainer CLI helpers) run unpatched.
  programs.nix-ld.enable = true;

  # 3. The admin user needs to talk to the Docker socket without root. This
  #    merges with the extraGroups list defined in modules/common.nix.
  users.users.rgpeach10.extraGroups = [ "docker" ];

  # 4. git + gh, handy on the host and required by many devcontainer flows.
  environment.systemPackages = [
    pkgs.git
    pkgs.gh
  ];

  # --- Automatic reboots for kernel/initrd updates --------------------------
  # Opt in to rebooting from the daily auto-upgrade (common.nix defaults it
  # off). This only reboots when the kernel/initrd actually change — not every
  # night — and only inside the window below, which brackets the 04:00 upgrade.
  # Combined with docker's enableOnBoot = false above, a reboot also cleanly
  # drops any containers that were left running.
  system.autoUpgrade = {
    allowReboot = true;
    rebootWindow = {
      lower = "03:00";
      upper = "06:00";
    };
  };

  # Should match the NixOS version this host was originally installed with.
  system.stateVersion = "25.05";
}
