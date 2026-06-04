# rgpeach10-mini — x86_64 mini PC.
{ config, ... }:
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

  # Should match the NixOS version this host was originally installed with.
  system.stateVersion = "25.05";
}
