# PLACEHOLDER hardware configuration for rgpeach10-mini.
#
# Replace this file with the real one generated on the machine:
#   nixos-generate-config --show-hardware-config > hardware-configuration.nix
#
# The values below are minimal defaults that let `nix build` evaluate the
# system closure in CI; they are NOT guaranteed correct for the real disk
# layout, so deploy with a generated config before relying on this host.
{
  lib,
  modulesPath,
  ...
}:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usbhid"
    "sd_mod"
  ];
  boot.kernelModules = [ "kvm-intel" ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
  };

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
