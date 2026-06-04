# rgpeach10-pi1 — aarch64 Raspberry Pi.
{ ... }:
{
  imports = [ ./hardware-configuration.nix ];

  # Raspberry Pi boots via U-Boot / generic extlinux, not GRUB or systemd-boot.
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  # Should match the NixOS version this host was originally installed with.
  system.stateVersion = "25.05";
}
