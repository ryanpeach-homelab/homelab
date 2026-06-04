# rgpeach10-mini — x86_64 mini PC.
{ pkgs, ... }:
{
  imports = [ ./hardware-configuration.nix ];

  # EFI / systemd-boot.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # --- ollama, exposed only over the tailnet --------------------------------
  # ollama listens on all interfaces but the firewall only opens 11434 on
  # tailscale0, so it is reachable on the tailnet and never on the LAN.
  services.ollama = {
    enable = true;
    host = "0.0.0.0";
    port = 11434;
  };
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 11434 ];

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
  virtualisation.docker = {
    enable = true;
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

  # Should match the NixOS version this host was originally installed with.
  system.stateVersion = "25.05";
}
