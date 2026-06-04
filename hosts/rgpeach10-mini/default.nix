# rgpeach10-mini — x86_64 mini PC.
{ ... }:
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

  # Should match the NixOS version this host was originally installed with.
  system.stateVersion = "25.05";
}
