# PLACEHOLDER hardware configuration for rgpeach10-pi1.
#
# Replace this file with the real one generated on the machine:
#   nixos-generate-config --show-hardware-config > hardware-configuration.nix
#
# The values below are minimal aarch64 / SD-card defaults that let `nix build`
# evaluate the system closure in CI; they are NOT guaranteed correct for the
# real disk layout, so deploy with a generated config before relying on this
# host.
{
  lib,
  modulesPath,
  ...
}:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [
    "usbhid"
    "usb_storage"
  ];
  boot.kernelModules = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
  };

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
