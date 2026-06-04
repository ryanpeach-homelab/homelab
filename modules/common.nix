# Shared configuration imported by every host.
{
  config,
  lib,
  pkgs,
  flakeUrl,
  ...
}:
{
  # --- Nix / flakes ---------------------------------------------------------
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    auto-optimise-store = true;
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  # --- GitOps pull-based deployment ----------------------------------------
  # CI builds every host on each PR. Once a PR merges to `main`, each host
  # periodically pulls the repo and rebuilds itself from the *locked* flake,
  # so every machine converges on exactly the closure CI validated.
  #
  # `--no-write-lock-file` + no `--update-input` means the host uses the
  # flake.lock committed to the repo rather than re-resolving inputs itself.
  system.autoUpgrade = {
    enable = true;
    flake = "${flakeUrl}#${config.networking.hostName}";
    flags = [
      "--no-write-lock-file"
      "-L"
    ];
    dates = "04:00";
    randomizedDelaySec = "45min";
    # Flip to true (and set a reboot window) if you want kernel/initrd updates
    # to take effect automatically.
    allowReboot = false;
  };

  # --- Remote access --------------------------------------------------------
  services.tailscale.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  networking.firewall.enable = true;

  # --- Admin user -----------------------------------------------------------
  users.users.rgpeach10 = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    # IMPORTANT: add your SSH public key(s) before the first deploy, otherwise
    # password auth is disabled and you will be locked out.
    openssh.authorizedKeys.keys = [
      # "ssh-ed25519 AAAA... you@host"
    ];
  };
  security.sudo.wheelNeedsPassword = lib.mkDefault false;

  time.timeZone = lib.mkDefault "America/New_York";
}
