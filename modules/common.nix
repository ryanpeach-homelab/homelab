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
    # to take effect automatically. mkDefault so individual hosts can opt in
    # (e.g. rgpeach10-mini does, see hosts/rgpeach10-mini/default.nix).
    allowReboot = lib.mkDefault false;
  };

  # Also re-pull + rebuild shortly after every boot — not just on the daily
  # timer above. This turns a reboot into a "reimage": power-cycle a host and it
  # fetches the latest locked flake from GitHub and rebuilds itself to match.
  # The autoUpgrade module creates `nixos-upgrade.{service,timer}`; we extend
  # that timer with an extra OnBootSec trigger (merged into its existing
  # OnCalendar config). The service already waits on network-online.target, so
  # the 2min delay is just slack for tailscale/DNS to settle before the pull.
  systemd.timers.nixos-upgrade.timerConfig.OnBootSec = "2min";

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

  # --- Synology NAS (NFS, all shares, on-demand) ---------------------------
  # autofs wildcard map: accessing /mnt/nas/<name> automounts
  # <NAS>:/volume1/<name> on demand, so *every* shared folder is reachable
  # without listing them here. Mounts are made lazily on first access and
  # unmounted after 10 min idle, so a host never blocks boot (or hangs) if the
  # NAS is offline. No credentials are needed for NFS.
  #
  # Synology exports each shared folder individually (there is no `/volume1`
  # export), so for a folder to actually mount it must have an NFS rule
  # permitting this host: Control Panel → Shared Folder → <share> → Edit →
  # NFS Permissions → add the host's IP/subnet (or the tailnet range
  # 100.64.0.0/10 if mounting over Tailscale).
  #
  # Note: a wildcard automount can't be browsed with `ls /mnt/nas` — you have
  # to reference a folder by name (e.g. `cd /mnt/nas/photos`) to trigger it.
  #
  # Set <NAS> below to the NAS address, e.g. "synology.<tailnet>.ts.net" or a
  # LAN IP like "192.168.1.20".
  services.autofs = {
    enable = true;
    autoMaster =
      let
        nasMap = pkgs.writeText "auto.nas" ''
          * -fstype=nfs4,rw,nfsvers=4.1,soft <NAS>:/volume1/&
        '';
      in
      ''
        /mnt/nas file:${nasMap} --timeout=600
      '';
  };

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
