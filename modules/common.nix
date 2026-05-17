{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  imports = [
    inputs.agenix.nixosModules.default
  ];

  # Disable mutable user state — everything declarative.
  users.mutableUsers = false;

  # Root: no password. SSH key-only via PermitRootLogin=prohibit-password.
  users.users.root = {
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKILtMsWYC08UX9hLc5OZaq14vXEn6dImCQH+exaptNw tmk@ext"
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCrAOmkF4mkiP1DL25fkvCl+UbLtjgiyUL6cuitIsFPlumVE+CRpOOiM6ylmSWFmwa9RTQ+b+SVpwqOp7QYJgzHHRJqa1e9CJt1eE28ZvOr8cLHAc5kmTgZFvTidPUOlXPwjd3g3wmp4iAK3/x5I7g8vVy9k6rlrUZ3GM+Jtq19GH3D6JfAYwz8GbEn6VUuBQqwlOQet3NkvcnalgB0Ndib0gkBI9kBEuS8r4mdsY/k2xvRBalUDRvgfzdUKwJp59FPnOLStrCz7mkzU6gEbUykF21vIlUMgOaVlPH/ZoXbKb6dRE7/SHLbn8uwBGHyPTecfaVr8qn8EU4K8paN/RITnJoL9gm9gs1BsUe+KNNnggMDGLs//+fWUreJ6GrUTBEoB4m1WZPnlO2pgKE+Xnp2I+YLkSxspj8yZKLB3tzAx7LJlhXMG1WAhryr3t9OfRMs+L+cp+OA7D3d8HvzmPvdVH8ycn8+Sj2K1j+ThEOPFSKXOdksIGd1LisNS1/TPI0jHv8O6MDUI38cAwq1Xqrk9mxH5j0pr0VpEbB9aQ7vLNvJUzAoh4opZ4U/7eX1rIgVjUlLADlBn+C34HXP7sl381rCfJn4SvXACc7vlP6rXdNVzeIMi0MW7uqecMrBnEISYEwi6uQnfz4bqQ/zGxZMTYAX4xysZr4onrG3bvcH3Q== tmk@ext"
    ];
  };

  # tmk: normal user, wheel, SSH key auth. hashedPasswordFile is set in
  # the per-host or non-bootstrap variant (via agenix); see Task 21.
  users.users.tmk = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    shell = pkgs.fish;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKILtMsWYC08UX9hLc5OZaq14vXEn6dImCQH+exaptNw tmk@ext"
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCrAOmkF4mkiP1DL25fkvCl+UbLtjgiyUL6cuitIsFPlumVE+CRpOOiM6ylmSWFmwa9RTQ+b+SVpwqOp7QYJgzHHRJqa1e9CJt1eE28ZvOr8cLHAc5kmTgZFvTidPUOlXPwjd3g3wmp4iAK3/x5I7g8vVy9k6rlrUZ3GM+Jtq19GH3D6JfAYwz8GbEn6VUuBQqwlOQet3NkvcnalgB0Ndib0gkBI9kBEuS8r4mdsY/k2xvRBalUDRvgfzdUKwJp59FPnOLStrCz7mkzU6gEbUykF21vIlUMgOaVlPH/ZoXbKb6dRE7/SHLbn8uwBGHyPTecfaVr8qn8EU4K8paN/RITnJoL9gm9gs1BsUe+KNNnggMDGLs//+fWUreJ6GrUTBEoB4m1WZPnlO2pgKE+Xnp2I+YLkSxspj8yZKLB3tzAx7LJlhXMG1WAhryr3t9OfRMs+L+cp+OA7D3d8HvzmPvdVH8ycn8+Sj2K1j+ThEOPFSKXOdksIGd1LisNS1/TPI0jHv8O6MDUI38cAwq1Xqrk9mxH5j0pr0VpEbB9aQ7vLNvJUzAoh4opZ4U/7eX1rIgVjUlLADlBn+C34HXP7sl381rCfJn4SvXACc7vlP6rXdNVzeIMi0MW7uqecMrBnEISYEwi6uQnfz4bqQ/zGxZMTYAX4xysZr4onrG3bvcH3Q== tmk@ext"
    ];
  };

  programs.fish.enable = true;
  programs.fish.useBabelfish = true;

  # No SSH password auth for anyone; root via key only.
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  # tmk can sudo without password (SSH-authenticated already; console
  # password is a breaking-glass thing only).
  security.sudo = {
    enable = true;
    wheelNeedsPassword = false;
  };

  environment.systemPackages = map lib.lowPrio [
    pkgs.vim
    pkgs.curl
    pkgs.gitMinimal
  ];

  # Public firewall: SSH, ACME HTTP-01 challenge, and fossil. Tailscale
  # opens UDP 41641 itself.
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22
      80
      443
    ];
  };

  # Kernel-level hardening. Zero maintenance cost, real defensive value.
  # Carried forward from ~/dev/playground/nixos-fossil/configuration.nix:241-274.
  boot.kernelModules = [ "tcp_bbr" ];
  boot.kernel.sysctl = {
    "kernel.sysrq" = 0;
    "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
    "net.ipv4.icmp_ignore_bogus_error_responses" = 1;
    "net.ipv4.conf.default.rp_filter" = 1;
    "net.ipv4.conf.all.rp_filter" = 1;
    "net.ipv4.tcp_syncookies" = 1;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv4.conf.all.secure_redirects" = 0;
    "net.ipv4.conf.default.secure_redirects" = 0;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv6.conf.default.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.all.accept_source_route" = 0;
    "net.ipv6.conf.all.accept_source_route" = 0;
    "net.ipv4.tcp_rfc1337" = 1;
    "net.ipv4.tcp_fastopen" = 3;
    "net.ipv4.tcp_congestion_control" = "bbr";
    "net.core.default_qdisc" = "cake";
  };

  # Atomic auto-upgrade with weekly reboot for kernel patches. Staggered
  # reboots so the 3 hosts don't reboot simultaneously.
  system.autoUpgrade = {
    enable = true;
    flake = "git+https://git.exidia.com/tmk/nixos-fossil?ref=main#${config.networking.hostName}";
    allowReboot = true;
    dates = "Sun 03:00 UTC";
    randomizedDelaySec = "30min";
  };

  # Keep nix store from growing unbounded.
  nix.gc = {
    automatic = true;
    dates = "Sunday 02:00 UTC";
    options = "--delete-older-than 14d";
  };

  # Cap journal disk usage.
  services.journald.extraConfig = ''
    SystemMaxUse=500M
    MaxRetentionSec=30day
  '';
}
