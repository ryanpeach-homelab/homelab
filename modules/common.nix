# Shared configuration imported by every host.
{
  config,
  lib,
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

  # SSH is enabled on every host (this module is imported by all of them).
  services.openssh = {
    enable = true;
    openFirewall = true; # allow port 22 through the firewall
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
    # Ensure an ed25519 host key exists — used both for SSH and to derive each
    # host's sops/age decryption key (see Secrets below).
    hostKeys = [
      {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
      {
        path = "/etc/ssh/ssh_host_rsa_key";
        type = "rsa";
        bits = 4096;
      }
    ];
  };

  networking.firewall.enable = true;

  # --- Secrets (sops-nix) ---------------------------------------------------
  # Each host decrypts secrets with an age key derived from its SSH ed25519
  # host key, so there is no separate key to distribute. Encrypt secrets with
  # the recipients listed in .sops.yaml, then declare them, e.g.:
  #
  #   sops.defaultSopsFile = ../secrets/common.yaml;
  #   sops.secrets."my-token" = { };          # -> /run/secrets/my-token
  #   sops.secrets."svc-pw".owner = "someuser";
  #
  # See secrets/README.md for the full workflow.
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

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
