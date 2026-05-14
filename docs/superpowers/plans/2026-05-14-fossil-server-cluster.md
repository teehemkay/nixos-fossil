# Fossil Server Cluster Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a three-host NixOS fossil-server cluster (one canonical + two secondaries) that hosts personal fossil repositories with native TLS, ACME via Cloudflare DNS-01, agenix-managed secrets, Tailscale, and automatic replication via systemd timers.

**Architecture:** Each host runs the same custom `services.fossilServer` NixOS module, parameterized by a `role` (canonical | secondary). Fossil serves TLS natively on :443. Secondaries pull from canonical every 5 minutes via `fossil all sync -u` — the canonical's URL is stored *per-repo* in each secondary's repo file (set once by `bin/new-repo.sh`), not in the module config. Secrets live in the repo encrypted with agenix; each host's SSH host key decrypts only the secrets it's authorized for. A bootstrap flake output per host (no agenix references) allows first install before host keys exist.

**Tech Stack:** NixOS (nixpkgs unstable), nix flakes, disko, agenix, nixos-anywhere, Tailscale, Fossil SCM (native TLS), Let's Encrypt via NixOS `security.acme` Cloudflare DNS-01, systemd timers, healthchecks.io.

**Spec reference:** `docs/superpowers/specs/2026-05-14-fossil-server-design.md` (all section references `§N` in this plan refer to that spec).

---

## Phase 1 — Repo Skeleton

### Task 1: Initialize flake.nix with inputs

**Files:**
- Create: `flake.nix`

- [ ] **Step 1: Write the initial flake.nix**

```nix
{
  description = "NixOS fossil-server cluster: canonical + 2 secondaries";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, agenix, ... }: {
    # nixosConfigurations populated by later tasks
    nixosConfigurations = { };
  };
}
```

- [ ] **Step 2: Verify the flake parses**

Run: `nix flake check --no-build`
Expected: succeeds with no outputs (the empty nixosConfigurations is valid).

- [ ] **Step 3: Commit**

```bash
git add flake.nix
git commit -m "feat: initial flake.nix with nixpkgs + disko + agenix inputs"
```

### Task 2: Create .gitignore

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Write .gitignore**

```
result
result-*
.direnv
*.qcow2
```

- [ ] **Step 2: Commit**

```bash
git add .gitignore
git commit -m "chore: add .gitignore for nix build artifacts"
```

### Task 3: Create secrets directory and recipient map skeleton

**Files:**
- Create: `secrets/secrets.nix`
- Create: `secrets/.gitkeep`

- [ ] **Step 1: Write secrets/secrets.nix**

```nix
# agenix recipient map: which keys decrypt which secrets.
#
# Each host's recipient is represented as a LIST that's empty on first
# setup and contains the host's `ssh_host_ed25519_key.pub` once the
# bootstrap install has produced one. Lists let us concatenate without
# inserting placeholder strings into publicKeys (which would break agenix).
#
# Bootstrap workflow:
#   1. Initial state: only `tmk` (SSH ed25519 pubkey) can encrypt/decrypt
#      anything. All host lists below are [].
#   2. For the FIRST encryption of each secret, the zero-byte placeholder
#      .age file (committed by the implementation plan) must be removed
#      before `agenix -e` runs, because agenix tries to decrypt any
#      existing file before opening the editor — and 0-byte content is
#      not valid age payload. Use:
#         rm secrets/<name>.age && agenix -e secrets/<name>.age
#      After the first successful encryption, subsequent rotations use
#      plain `agenix -e secrets/<name>.age` (the file now holds valid
#      age content that agenix can decrypt).
#   3. After each host's bootstrap install, capture its host pubkey from
#      /etc/ssh/ssh_host_ed25519_key.pub. Set the corresponding list
#      below to [ "ssh-ed25519 AAAA... root@<host>" ]. Run `agenix --rekey`
#      to re-encrypt every affected secret so the new host can read it.
let
  # Admin: tmk's existing SSH ed25519 public key. agenix accepts SSH
  # ed25519 keys as age recipients and finds them at ~/.ssh/id_ed25519
  # automatically for decryption, so no separate age-keygen or -i flag
  # is needed. Print yours with `cat ~/.ssh/id_ed25519.pub` and paste
  # the full line here BEFORE first encryption.
  tmk = "ssh-ed25519 AAAA-placeholder-replace-with-tmk-laptop-ssh-ed25519-pubkey tmk@laptop";

  # Host SSH host pubkeys, as lists. Empty until each host is provisioned.
  # After provisioning, set to [ "ssh-ed25519 AAAA... root@<host>" ] then
  # run `agenix --rekey`.
  canonicalHost   = [ ];  # e.g. [ "ssh-ed25519 AAAA... root@canonical" ]
  secondary1Host  = [ ];
  secondary2Host  = [ ];

  allHosts = canonicalHost ++ secondary1Host ++ secondary2Host;
in
{
  # Cloudflare DNS-01 API token: every host's ACME service reads it.
  "cloudflare-dns.age".publicKeys = [ tmk ] ++ allHosts;

  # Fossil sync user password: secondaries embed it in repo remote URLs;
  # canonical needs it to create the per-repo syncuser via bin/new-repo.sh.
  "fossil-sync.age".publicKeys = [ tmk ] ++ allHosts;

  # tmk's console-fallback password (breaking-glass only).
  "tmk-password.age".publicKeys = [ tmk ] ++ allHosts;

  # Tailscale auth keys: one per host, only that host decrypts.
  "tailscale-authkey-canonical.age".publicKeys    = [ tmk ] ++ canonicalHost;
  "tailscale-authkey-secondary-1.age".publicKeys  = [ tmk ] ++ secondary1Host;
  "tailscale-authkey-secondary-2.age".publicKeys  = [ tmk ] ++ secondary2Host;

  # healthchecks.io ping URLs: only secondaries need them.
  "healthchecks-secondary-1.age".publicKeys = [ tmk ] ++ secondary1Host;
  "healthchecks-secondary-2.age".publicKeys = [ tmk ] ++ secondary2Host;
}
```

- [ ] **Step 2: Touch .gitkeep and zero-byte placeholder .age files**

The `.age` files don't exist yet — they get encrypted by the operator during initial bootstrap (see Task 26 → setup.org). But the host configs (Tasks 15, 17, 18) reference them via Nix path literals like `../secrets/cloudflare-dns.age`, and Nix forces those paths during eval (`.drvPath`). So if the files don't exist, our eval-test verification in Task 35 fails with "no such file" *before* the operator has any chance to encrypt them.

Solution: commit zero-byte placeholder files. They satisfy Nix's path-literal resolution. agenix only reads file *content* at activation time, not at eval, so 0-byte placeholders pass eval cleanly.

Important caveat for the operator: `agenix -e <name>.age` won't work directly against a 0-byte placeholder (agenix tries to decrypt the existing file first, and 0-byte isn't valid age content). The setup workflow in Task 26 explicitly uses `rm secrets/<name>.age && agenix -e secrets/<name>.age` for each *initial* encryption to clear the placeholder first. Subsequent rotations use plain `agenix -e` once the file holds real encrypted content.

```bash
touch secrets/.gitkeep
touch secrets/cloudflare-dns.age \
      secrets/fossil-sync.age \
      secrets/tmk-password.age \
      secrets/tailscale-authkey-canonical.age \
      secrets/tailscale-authkey-secondary-1.age \
      secrets/tailscale-authkey-secondary-2.age \
      secrets/healthchecks-secondary-1.age \
      secrets/healthchecks-secondary-2.age
```

- [ ] **Step 3: Verify the secrets.nix is parseable Nix**

Run: `nix-instantiate --eval secrets/secrets.nix --strict 2>&1 | head -20`
Expected: prints an attribute set; no syntax errors. (The `tmk` placeholder string is just a text value; agenix won't actually use it until the operator replaces it with a real age public key before the first `agenix -e` invocation.)

- [ ] **Step 4: Commit**

```bash
git add secrets/secrets.nix secrets/.gitkeep secrets/*.age
git commit -m "feat: agenix recipient map skeleton + 0-byte secret placeholders"
```

### Task 4: Document the admin keypair generation

**Files:**
- Create: `docs/setup.org` (initial skeleton; expanded in later tasks)

- [ ] **Step 1: Write the bootstrap section of docs/setup.org**

```org
#+TITLE: Setup
#+OPTIONS: toc:2

* Initial bootstrap

This section is for first-time setup of the whole project. Run once.

** 1. Register your SSH key as the agenix admin recipient

agenix uses your SSH ed25519 key as both the recipient (encrypts the
secrets so you can read them) and the identity (decrypts when you edit
or rekey). agenix finds it automatically at =~/.ssh/id_ed25519=, so
no extra flag is needed on any =agenix= command.

Print your SSH public key:

#+begin_src bash
cat ~/.ssh/id_ed25519.pub
#+end_src

Edit =secrets/secrets.nix= and replace the =tmk= placeholder string
with the full line from your =id_ed25519.pub=.

#+begin_src bash
${EDITOR:-vim} secrets/secrets.nix
#+end_src

Back up =~/.ssh/id_ed25519= (the private half) somewhere safe — 1Password
or equivalent. Losing it means losing decrypt access to every secret in
the repo until you provision a new host whose key is also a recipient.

** 2. Cloudflare account + DNS-01 API token

(documented in a later task)

** 3. Delegate fossil.exidia.com to Cloudflare

(documented in a later task)
```

- [ ] **Step 2: Commit**

```bash
git add docs/setup.org
git commit -m "docs: skeleton setup.org with admin keypair bootstrap section"
```

---

## Phase 2 — Common Module

The common module holds everything every host shares: users, SSH, sudo, sysctl, firewall, Tailscale, auto-upgrade, journald, nix GC. It's imported by every host's config.

### Task 5: Create modules/common.nix with users and SSH

**Files:**
- Create: `modules/common.nix`

- [ ] **Step 1: Write the initial modules/common.nix**

```nix
{ config, lib, pkgs, ... }:

{
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
    pkgs.vim pkgs.curl pkgs.gitMinimal
  ];
}
```

- [ ] **Step 2: Commit**

```bash
git add modules/common.nix
git commit -m "feat: common.nix with users, ssh, sudo, fish"
```

### Task 6: Add firewall and sysctl hardening to common.nix

**Files:**
- Modify: `modules/common.nix`

- [ ] **Step 1: Append firewall and sysctl blocks**

Append to the end of `modules/common.nix` (before the final `}`):

```nix
  # Public firewall: SSH and fossil only. Tailscale opens UDP 41641 itself.
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 443 ];
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
```

- [ ] **Step 2: Commit**

```bash
git add modules/common.nix
git commit -m "feat: common.nix firewall + sysctl hardening"
```

### Task 7: Add auto-upgrade, nix GC, journald to common.nix

**Files:**
- Modify: `modules/common.nix`

- [ ] **Step 1: Append the three sections**

Append to the end of `modules/common.nix` (before the final `}`):

```nix
  # Atomic auto-upgrade with weekly reboot for kernel patches. Staggered
  # reboots so the 3 hosts don't reboot simultaneously.
  system.autoUpgrade = {
    enable = true;
    flake = "github:teehemkay/nixos-fossil#${config.networking.hostName}";
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
```

- [ ] **Step 2: Commit**

```bash
git add modules/common.nix
git commit -m "feat: common.nix autoUpgrade + nix gc + journald caps"
```

### Task 8: Import agenix module into common.nix

**Files:**
- Modify: `modules/common.nix`

`common.nix` is the truly-shared base: users (without passwords), SSH, sudo, firewall, sysctl, autoUpgrade, journald, nix.gc, fish, packages. All of those work without any agenix secret. Agenix-dependent wiring (Tailscale, fossil server, tmk hashedPasswordFile, age.secrets entries) lives in per-host files so bootstrap variants — which can't decrypt anything yet — can omit them by not importing the per-host config.

We DO need `common.nix` to import the agenix NixOS module, so that `age.secrets` is a valid option (used by per-host files later).

- [ ] **Step 1: Update common.nix's function signature + add agenix module import**

Replace the opening of `modules/common.nix` so it accepts `inputs` from the flake and imports the agenix module:

```nix
{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    inputs.agenix.nixosModules.default
  ];
```

(Leave everything else in the file as-is.)

- [ ] **Step 2: Commit**

```bash
git add modules/common.nix
git commit -m "feat: common.nix imports agenix module (no secrets declared here)"
```

---

## Phase 3 — Disko Module

### Task 9: Create modules/disko.nix

**Files:**
- Create: `modules/disko.nix`

- [ ] **Step 1: Write the disk layout**

```nix
{ lib, ... }:
{
  disko.devices = {
    disk.disk1 = {
      device = lib.mkDefault "/dev/sda";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          boot = { name = "boot"; size = "1M"; type = "EF02"; };
          esp = {
            name = "ESP";
            size = "500M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };
          root = {
            name = "root";
            size = "100%";
            content = {
              type = "lvm_pv";
              vg = "pool";
            };
          };
        };
      };
    };
    lvm_vg.pool = {
      type = "lvm_vg";
      lvs.root = {
        size = "100%FREE";
        content = {
          type = "filesystem";
          format = "ext4";
          mountpoint = "/";
          mountOptions = [ "defaults" ];
        };
      };
    };
  };
}
```

`lib.mkDefault` lets per-host configs override the device path (e.g. DigitalOcean uses `/dev/vda`).

- [ ] **Step 2: Commit**

```bash
git add modules/disko.nix
git commit -m "feat: disko.nix with mkDefault device path"
```

---

## Phase 4 — Fossil Server Module

This is the largest module. Build it in steps: options → user/dirs → ACME → server unit → sync unit/timer (secondary only).

### Task 10: Create modules/fossil-server.nix with options skeleton

**Files:**
- Create: `modules/fossil-server.nix`

- [ ] **Step 1: Write the options block**

```nix
{ config, lib, pkgs, ... }:

let cfg = config.services.fossilServer;
in {
  options.services.fossilServer = {
    enable = lib.mkEnableOption "Fossil server (native TLS, repolist, optional sync timer)";

    role = lib.mkOption {
      type = lib.types.enum [ "canonical" "secondary" ];
      description = "Cluster role. Only secondaries run the sync timer.";
    };

    domain = lib.mkOption {
      type = lib.types.str;
      example = "fossil.exidia.com";
      description = "DNS name fossil serves. ACME requests a cert for this.";
    };

    repoDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/fossil/museum";
      description = "Directory holding the .fossil files served by --repolist.";
    };

    # NOTE: there was a syncCredentialFile option here in earlier plan
    # drafts. It was removed because the module never read it — the sync
    # password is consumed by bin/new-repo.sh and the rotation runbook,
    # which read it on the host from /run/agenix/fossil-sync
    # (i.e. config.age.secrets.fossil-sync.path after activation, the
    # only consumer of the path). Same shape as the canonicalUrl removal.

    syncInterval = lib.mkOption {
      type = lib.types.str;
      default = "*:0/5";
      description = "systemd OnCalendar expression for the sync timer.";
    };

    healthcheckUrlFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to the agenix-decrypted file containing the healthchecks.io
        ping URL (one line). null disables monitoring.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # populated by subsequent tasks
  };
}
```

- [ ] **Step 2: Verify the module syntax-checks**

Run: `nix-instantiate --parse modules/fossil-server.nix > /dev/null`
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add modules/fossil-server.nix
git commit -m "feat: fossil-server.nix options skeleton"
```

### Task 11: Add fossil user, group, repo dir to fossil-server.nix

**Files:**
- Modify: `modules/fossil-server.nix`

- [ ] **Step 1: Replace the empty config block**

Replace `config = lib.mkIf cfg.enable { ... };` with:

```nix
  config = lib.mkIf cfg.enable {
    users.groups.fossil = { };
    users.users.fossil = {
      isSystemUser = true;
      group = "fossil";
      # Home is /var/lib/fossil so fossil's $HOME/.fossil global config
      # (the "all repositories" list) lives at /var/lib/fossil/.fossil.
      # Without an explicit home, NixOS would default to /var/empty and
      # `fossil all add` would fail silently. createHome ensures the dir
      # exists with right ownership on first activation.
      home = "/var/lib/fossil";
      createHome = true;
      # Non-login user — no shell, no SSH access.
      shell = pkgs.shadow + "/bin/nologin";
    };

    # Ensure the repolist dir exists. We don't strictly need this on top
    # of createHome (because repoDir is under the home), but being explicit
    # keeps the mode/owner enforced by NixOS' systemd-tmpfiles.
    systemd.tmpfiles.rules = [
      "d ${cfg.repoDir} 0750 fossil fossil -"
    ];
  };
```

- [ ] **Step 2: Commit**

```bash
git add modules/fossil-server.nix
git commit -m "feat: fossil-server.nix declares fossil user + repoDir"
```

### Task 12: Add ACME (Cloudflare DNS-01) cert request to fossil-server.nix

**Files:**
- Modify: `modules/fossil-server.nix`

- [ ] **Step 1: Append the security.acme block inside `config = lib.mkIf cfg.enable { ... }`**

Inside the `config = ...` block (just before the closing `};`):

```nix
    security.acme = {
      acceptTerms = true;
      defaults.email = "tmk@fastmail.fm";
    };
    security.acme.certs.${cfg.domain} = {
      dnsProvider = "cloudflare";
      # The credentials file is sourced as a shell env file. agenix
      # decrypts cloudflare-dns.age to this path; its contents must be:
      #
      #     CLOUDFLARE_DNS_API_TOKEN=<your-token>
      #
      # (See docs/setup.org for token-scope guidance.)
      environmentFile = config.age.secrets.cloudflare-dns.path;
      group = "fossil";   # so the fossil service can read fullchain.pem + key.pem
      reloadServices = [ "fossil-server.service" ];
    };
```

- [ ] **Step 2: Commit**

```bash
git add modules/fossil-server.nix
git commit -m "feat: fossil-server.nix requests ACME cert via Cloudflare DNS-01"
```

### Task 13: Add fossil-server.service unit to fossil-server.nix

**Files:**
- Modify: `modules/fossil-server.nix`

- [ ] **Step 1: Append the systemd service block inside `config = ...`**

```nix
    systemd.services.fossil-server = {
      description = "Fossil SCM server (native TLS)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "acme-${cfg.domain}.service" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        # Must start as root to bind :443. Fossil reads --cert and --pkey
        # then chroots into the repoDir and setuids to the fossil user.
        User = "root";
        ExecStart = let
          certDir = "/var/lib/acme/${cfg.domain}";
        in ''
          ${pkgs.fossil}/bin/fossil server \
            --port 443 \
            --cert ${certDir}/fullchain.pem \
            --pkey ${certDir}/key.pem \
            --repolist \
            --baseurl https://${cfg.domain}/ \
            --jsmode bundled \
            ${cfg.repoDir}
        '';
        # Notes on the argument shape (verified against fossil's
        # src/main.c:2976 — `find_option("repolist", 0, 0)`):
        #   - `--repolist` is a BOOLEAN flag (no value), enabling
        #     directory-listing behavior when the positional REPOSITORY
        #     argument is a directory.
        #   - The REPOSITORY (or directory) is the trailing POSITIONAL
        #     argument — `${cfg.repoDir}` at the end.

        Restart = "always";
        RestartSec = 3;

        # systemd hardening: blocks setuid-up, allows fossil's setuid-down.
        NoNewPrivileges = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ "/var/lib/fossil" ];
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
      };
    };
```

- [ ] **Step 2: Commit**

```bash
git add modules/fossil-server.nix
git commit -m "feat: fossil-server.nix defines fossil-server.service"
```

### Task 14: Add fossil-sync timer + service (secondary role only) to fossil-server.nix

**Files:**
- Modify: `modules/fossil-server.nix`

- [ ] **Step 1: Append the conditional sync block inside `config = ...`**

```nix
    # Secondaries pull (and push back local writes) every syncInterval.
    # The systemd timer fires the service; the service runs as the fossil
    # user (so $HOME=/var/lib/fossil is set automatically from passwd) and
    # exits when sync completes. On success, ping healthchecks.io.
    systemd.timers.fossil-sync = lib.mkIf (cfg.role == "secondary") {
      description = "Fossil cluster sync (pull + push) every ${cfg.syncInterval}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.syncInterval;
        Persistent = true;
        RandomizedDelaySec = "30s";
      };
    };

    systemd.services.fossil-sync = lib.mkIf (cfg.role == "secondary") {
      description = "Fossil cluster sync (oneshot)";
      after = [ "network-online.target" "fossil-server.service" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "fossil";
        Group = "fossil";
        # `fossil all sync -u` walks the user's "all" list (in
        # /var/lib/fossil/.fossil) and syncs each repo against its stored
        # remote URL. -u also syncs unversioned content.
        ExecStart = "${pkgs.fossil}/bin/fossil all sync -u";
        # On success, ping healthchecks.io if a URL file is provided.
        # `cat` reads the agenix-decrypted file; -fsSL keeps curl quiet
        # but reports failure exit codes.
        ExecStartPost = lib.mkIf (cfg.healthcheckUrlFile != null) (
          pkgs.writeShellScript "fossil-sync-healthcheck" ''
            url=$(${pkgs.coreutils}/bin/cat ${cfg.healthcheckUrlFile})
            ${pkgs.curl}/bin/curl -fsSL -m 10 --retry 3 "$url" || true
          ''
        );
      };
    };
  };  # end of `config = lib.mkIf cfg.enable { ... }`
}     # end of the module function
```

(The final `};` closes `config = ...`; the outer `}` closes the function. Verify your file ends with both.)

- [ ] **Step 2: Verify the module evaluates**

Run: `nix eval --raw --impure --expr 'let nixpkgs = import <nixpkgs> {}; in builtins.toJSON (import ./modules/fossil-server.nix { config = {}; lib = nixpkgs.lib; pkgs = nixpkgs; }).options.services.fossilServer.role.type.name'` (this is a smoke check that the file parses and the options are wired)
Expected: prints `"enum"` (or similar non-error output).

If that's too fiddly, just rely on the per-target eval later. Minimum check:

Run: `nix-instantiate --parse modules/fossil-server.nix > /dev/null`
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
git add modules/fossil-server.nix
git commit -m "feat: fossil-server.nix sync timer + service (secondary only)"
```

---

## Phase 5 — Per-Host Configs and Flake Outputs

### Task 15: Create hosts/canonical.nix

**Files:**
- Create: `hosts/canonical.nix`

This host file declares EVERY agenix-dependent thing the canonical needs: the secrets themselves, Tailscale, tmk's console password, and the fossil-server role. The bootstrap variant (next task) imports `common.nix` directly and skips all of this, so no `mkForce` games are needed.

- [ ] **Step 1: Write the canonical host config**

```nix
{ config, lib, pkgs, inputs, ... }:

{
  # NOTE: hardware-config import (./canonical-hardware.nix or the fixture
  # used for eval-test) is composed in flake.nix by the helpers `mkHost`
  # / `mkHostBootstrap` / `mkHostEvalTest`, NOT here. This keeps the
  # throwing placeholder file out of imports so eval-test can substitute
  # a non-throwing fixture without the throw firing during module load.
  imports = [
    ../modules/common.nix
    ../modules/disko.nix
    ../modules/fossil-server.nix
  ];

  networking.hostName = "canonical";

  # Hetzner Cloud instances mount the OS disk at /dev/sda — the default
  # in modules/disko.nix. DigitalOcean uses /dev/vda; that override is
  # in secondary-2.nix.

  # Agenix-decrypted secrets this host consumes. All entries here MUST
  # have the canonical host's pubkey in their `publicKeys` list in
  # secrets/secrets.nix.
  age.secrets = {
    cloudflare-dns.file = ../secrets/cloudflare-dns.age;
    fossil-sync = {
      file = ../secrets/fossil-sync.age;
      # Make fossil-sync readable by the fossil group (consumed by
      # bin/new-repo.sh's sudo -u fossil invocations).
      owner = "fossil";
      group = "fossil";
      mode = "0440";
    };
    tmk-password.file = ../secrets/tmk-password.age;
    "tailscale-authkey-canonical".file = ../secrets/tailscale-authkey-canonical.age;
  };

  # Tailscale: agenix-decrypted auth key, auto-connects on first boot.
  services.tailscale = {
    enable = true;
    authKeyFile = config.age.secrets."tailscale-authkey-canonical".path;
  };

  # tmk's breaking-glass console password.
  users.users.tmk.hashedPasswordFile = config.age.secrets.tmk-password.path;

  # Fossil cluster role.
  services.fossilServer = {
    enable = true;
    role = "canonical";
    domain = "fossil.exidia.com";
    # No healthcheckUrlFile — canonical isn't monitored (no sync timer).
  };

  # NixOS state version: pinned to the release this host was first
  # installed against. Do not change after first deploy.
  system.stateVersion = "26.05";
}
```

- [ ] **Step 2: Commit**

```bash
git add hosts/canonical.nix
git commit -m "feat: hosts/canonical.nix"
```

### Task 16: Create hosts/canonical-hardware.nix placeholder

**Files:**
- Create: `hosts/canonical-hardware.nix`

- [ ] **Step 1: Write the placeholder**

```nix
# This file is generated at deploy time by:
#   nixos-anywhere --flake .#canonical-bootstrap \
#                  --generate-hardware-config nixos-generate-config \
#                  ./hosts/canonical-hardware.nix \
#                  --target-host root@<ip>
#
# Until then, evaluating this host will throw with the message below.
# That is intentional and matches the upstream `nixos-anywhere-examples`
# pattern for not-yet-provisioned hosts.
throw ''
  hosts/canonical-hardware.nix is a placeholder.

  Run `nixos-anywhere --flake .#canonical-bootstrap \
    --generate-hardware-config nixos-generate-config \
    ./hosts/canonical-hardware.nix --target-host root@<ip>`
  to populate it during the bootstrap install.
''
```

- [ ] **Step 2: Commit**

```bash
git add hosts/canonical-hardware.nix
git commit -m "feat: hosts/canonical-hardware.nix placeholder (throws until provisioned)"
```

### Task 17: Create hosts/secondary-1.nix and -hardware.nix placeholder

**Files:**
- Create: `hosts/secondary-1.nix`
- Create: `hosts/secondary-1-hardware.nix`

- [ ] **Step 1: Write secondary-1.nix**

```nix
{ config, lib, pkgs, inputs, ... }:

{
  # Hardware-config import is composed by flake.nix's helpers, not here.
  # See hosts/canonical.nix for the rationale.
  imports = [
    ../modules/common.nix
    ../modules/disko.nix
    ../modules/fossil-server.nix
  ];

  networking.hostName = "secondary-1";

  # Agenix-decrypted secrets this host consumes.
  age.secrets = {
    cloudflare-dns.file = ../secrets/cloudflare-dns.age;
    fossil-sync = {
      file = ../secrets/fossil-sync.age;
      owner = "fossil";
      group = "fossil";
      mode = "0440";
    };
    tmk-password.file = ../secrets/tmk-password.age;
    "tailscale-authkey-secondary-1".file = ../secrets/tailscale-authkey-secondary-1.age;
    "healthchecks-secondary-1" = {
      file = ../secrets/healthchecks-secondary-1.age;
      owner = "fossil";
      group = "fossil";
      mode = "0440";
    };
  };

  services.tailscale = {
    enable = true;
    authKeyFile = config.age.secrets."tailscale-authkey-secondary-1".path;
  };

  users.users.tmk.hashedPasswordFile = config.age.secrets.tmk-password.path;

  services.fossilServer = {
    enable = true;
    role = "secondary";
    domain = "s1.fossil.exidia.com";
    healthcheckUrlFile = config.age.secrets."healthchecks-secondary-1".path;
  };

  system.stateVersion = "26.05";
}
```

- [ ] **Step 2: Write secondary-1-hardware.nix placeholder**

```nix
throw ''
  hosts/secondary-1-hardware.nix is a placeholder.

  Run `nixos-anywhere --flake .#secondary-1-bootstrap \
    --generate-hardware-config nixos-generate-config \
    ./hosts/secondary-1-hardware.nix --target-host root@<ip>`
  to populate it during the bootstrap install.
''
```

- [ ] **Step 3: Commit**

```bash
git add hosts/secondary-1.nix hosts/secondary-1-hardware.nix
git commit -m "feat: hosts/secondary-1.{nix,hardware.nix}"
```

### Task 18: Create hosts/secondary-2.nix and -hardware.nix placeholder

**Files:**
- Create: `hosts/secondary-2.nix`
- Create: `hosts/secondary-2-hardware.nix`

- [ ] **Step 1: Write secondary-2.nix**

Same shape as `secondary-1.nix`. Note the DigitalOcean-specific disk path override.

```nix
{ config, lib, pkgs, inputs, ... }:

{
  # Hardware-config import is composed by flake.nix's helpers, not here.
  # See hosts/canonical.nix for the rationale.
  imports = [
    ../modules/common.nix
    ../modules/disko.nix
    ../modules/fossil-server.nix
  ];

  networking.hostName = "secondary-2";

  # DigitalOcean droplets use /dev/vda, not /dev/sda. modules/disko.nix
  # declared disk1.device with mkDefault so we override here.
  disko.devices.disk.disk1.device = "/dev/vda";

  # Agenix-decrypted secrets this host consumes.
  age.secrets = {
    cloudflare-dns.file = ../secrets/cloudflare-dns.age;
    fossil-sync = {
      file = ../secrets/fossil-sync.age;
      owner = "fossil";
      group = "fossil";
      mode = "0440";
    };
    tmk-password.file = ../secrets/tmk-password.age;
    "tailscale-authkey-secondary-2".file = ../secrets/tailscale-authkey-secondary-2.age;
    "healthchecks-secondary-2" = {
      file = ../secrets/healthchecks-secondary-2.age;
      owner = "fossil";
      group = "fossil";
      mode = "0440";
    };
  };

  services.tailscale = {
    enable = true;
    authKeyFile = config.age.secrets."tailscale-authkey-secondary-2".path;
  };

  users.users.tmk.hashedPasswordFile = config.age.secrets.tmk-password.path;

  services.fossilServer = {
    enable = true;
    role = "secondary";
    domain = "s2.fossil.exidia.com";
    healthcheckUrlFile = config.age.secrets."healthchecks-secondary-2".path;
  };

  system.stateVersion = "26.05";
}
```

- [ ] **Step 2: Write secondary-2-hardware.nix placeholder**

```nix
throw ''
  hosts/secondary-2-hardware.nix is a placeholder.

  Run `nixos-anywhere --flake .#secondary-2-bootstrap \
    --generate-hardware-config nixos-generate-config \
    ./hosts/secondary-2-hardware.nix --target-host root@<ip>`
  to populate it during the bootstrap install.
''
```

- [ ] **Step 3: Commit**

```bash
git add hosts/secondary-2.nix hosts/secondary-2-hardware.nix
git commit -m "feat: hosts/secondary-2.{nix,hardware.nix} (DO /dev/vda)"
```

### Task 19: Wire all six flake outputs (3 full + 3 bootstrap)

**Files:**
- Modify: `flake.nix`

- [ ] **Step 1: Replace the empty nixosConfigurations**

Replace the existing `outputs` section with:

```nix
  outputs = { self, nixpkgs, disko, agenix, ... }@inputs:
    let
      system = "x86_64-linux";

      # Helper: build a full nixosConfiguration for one host.
      # Hardware-config is composed here (not inside the host file) so the
      # eval-test helper below can swap it for a non-throwing fixture.
      mkHost = name: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [
          disko.nixosModules.disko
          ./hosts/${name}.nix
          ./hosts/${name}-hardware.nix
        ];
      };

      # Helper: build the bootstrap variant. Reuses common.nix + disko +
      # the throwing hardware-config (which is harmless on first
      # nixos-anywhere install because hardware-config gets regenerated
      # immediately as part of the install). Skips fossil-server, agenix,
      # tailscale, and tmk hashedPasswordFile.
      mkHostBootstrap = name: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [
          disko.nixosModules.disko
          ./hosts/${name}-bootstrap.nix
          ./hosts/${name}-hardware.nix
        ];
      };
    in {
      nixosConfigurations = {
        canonical             = mkHost          "canonical";
        canonical-bootstrap   = mkHostBootstrap "canonical";
        secondary-1           = mkHost          "secondary-1";
        secondary-1-bootstrap = mkHostBootstrap "secondary-1";
        secondary-2           = mkHost          "secondary-2";
        secondary-2-bootstrap = mkHostBootstrap "secondary-2";
      };
    };
```

- [ ] **Step 2: Run `nix flake check` to surface what's missing**

Run: `nix flake check --no-build 2>&1 | head -40`
Expected: errors about missing `hosts/<name>-bootstrap.nix` files (we haven't created them yet — next tasks fix this). The non-bootstrap configs may also fail because the agenix `.age` files don't exist yet — that's expected too.

- [ ] **Step 3: Commit**

```bash
git add flake.nix
git commit -m "feat: flake.nix exposes 3 full + 3 bootstrap nixosConfigurations"
```

### Task 20: Create bootstrap host files (one per host)

**Files:**
- Create: `hosts/canonical-bootstrap.nix`
- Create: `hosts/secondary-1-bootstrap.nix`
- Create: `hosts/secondary-2-bootstrap.nix`

The bootstrap config is what `nixos-anywhere` activates *first*, before the host's SSH host key has been added to `secrets/secrets.nix`. Because `common.nix` deliberately holds no agenix-dependent wiring, the bootstrap configs can simply import `common.nix` + `disko.nix` + the hardware-config placeholder. No `mkForce`, no secret references — just the shared base.

After the bootstrap install succeeds, capture the host's `ssh_host_ed25519_key.pub`, add it to `secrets/secrets.nix`, run `agenix --rekey`, then promote with `nixos-rebuild switch --flake .#<host>` (the full host config that DOES reference secrets).

- [ ] **Step 1: Write hosts/canonical-bootstrap.nix**

```nix
{ config, lib, pkgs, inputs, ... }:

{
  # Hardware-config import is composed by flake.nix's helpers, not here.
  imports = [
    ../modules/common.nix    # users (no password), ssh, sudo, sysctl, firewall, autoUpgrade, etc.
    ../modules/disko.nix
  ];

  networking.hostName = "canonical";

  system.stateVersion = "26.05";
}
```

- [ ] **Step 2: Write hosts/secondary-1-bootstrap.nix**

```nix
{ config, lib, pkgs, inputs, ... }:

{
  # Hardware-config import is composed by flake.nix's helpers, not here.
  imports = [
    ../modules/common.nix
    ../modules/disko.nix
  ];

  networking.hostName = "secondary-1";

  system.stateVersion = "26.05";
}
```

- [ ] **Step 3: Write hosts/secondary-2-bootstrap.nix**

```nix
{ config, lib, pkgs, inputs, ... }:

{
  # Hardware-config import is composed by flake.nix's helpers, not here.
  imports = [
    ../modules/common.nix
    ../modules/disko.nix
  ];

  networking.hostName = "secondary-2";
  disko.devices.disk.disk1.device = "/dev/vda";

  system.stateVersion = "26.05";
}
```

- [ ] **Step 4: Commit**

```bash
git add hosts/canonical-bootstrap.nix hosts/secondary-1-bootstrap.nix hosts/secondary-2-bootstrap.nix
git commit -m "feat: bootstrap host variants (common.nix only, no agenix)"
```

---

## Phase 6 — Pre-Deploy Verification

### Task 21: Run flake check; expect hardware-config throws

**Files:**
- (verification only; no files changed)

- [ ] **Step 1: Run nix flake check**

Run: `nix flake check 2>&1 | tail -30`
Expected: errors of the form "hosts/canonical-hardware.nix is a placeholder" for at least one host (the others may not even be reached because flake check aborts at the first failure).

This is the same intentional throw pattern used by `nix-community/nixos-anywhere-examples`. The placeholder gets populated at deploy time.

- [ ] **Step 2: Run per-target eval for each bootstrap output**

```bash
for target in canonical-bootstrap secondary-1-bootstrap secondary-2-bootstrap; do
  echo "=== $target ==="
  nix eval ".#nixosConfigurations.$target.config.system.build.toplevel.drvPath" --raw 2>&1 | tail -3
  echo ""
done
```

Expected: all three throw the same "hosts/<name>-hardware.nix is a placeholder" error. This is expected — the bootstrap configs also import the hardware placeholder.

If they fail for any *other* reason (e.g. "infinite recursion", "attribute not found"), that's a real bug in the module wiring; investigate.

- [ ] **Step 3: Commit a note (no code change)**

Nothing to commit — this is verification.

### Task 21b: Add a fixture-hardware module and three eval-test flake outputs

**Files:**
- Create: `hosts/_fixture-hardware.nix`
- Modify: `flake.nix`

The real `hosts/<name>-hardware.nix` files throw on every evaluation, which guards against accidental deployment of un-provisioned hosts but also masks any wiring errors below the throw. To verify that the *rest* of each host's wiring evaluates cleanly — module options, agenix paths, fossil-server service definition, secondary sync timer, etc. — we provide a tiny non-throwing fixture and three additional flake outputs that swap it in.

These outputs are for *pre-deploy verification only*. They share the host's everything except hardware-config. The real `<host>` and `<host>-bootstrap` outputs still throw on hardware as designed.

- [ ] **Step 1: Write hosts/_fixture-hardware.nix**

```nix
# Test fixture — provides the minimum NixOS needs for a host config to
# evaluate without performing a real hardware scan. Not for deployment.
{ lib, ... }:
{
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  # Disko declares the filesystem layout; we only need to satisfy the
  # boot loader and any imports that look at boot.initrd here.
  boot.initrd.availableKernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];
}
```

- [ ] **Step 2: Add `<host>-eval-test` outputs to flake.nix**

Add to `flake.nix`'s `let ... in` block (next to `mkHost` / `mkHostBootstrap`):

```nix
      # Helper: build an eval-test variant of a host. Imports the host
      # config but with the non-throwing fixture in place of the real
      # hardware-config. Only for verifying that module wiring evaluates;
      # NOT deployable. Because the host file (hosts/<name>.nix) no longer
      # imports its hardware-config directly, we can simply NOT import
      # ./hosts/${name}-hardware.nix here — no disabledModules trickery.
      mkHostEvalTest = name: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [
          disko.nixosModules.disko
          ./hosts/${name}.nix
          ./hosts/_fixture-hardware.nix
        ];
      };
```

Then in the `nixosConfigurations` attrset, add:

```nix
        canonical-eval-test    = mkHostEvalTest "canonical";
        secondary-1-eval-test  = mkHostEvalTest "secondary-1";
        secondary-2-eval-test  = mkHostEvalTest "secondary-2";
```

- [ ] **Step 3: Verify the eval-test outputs parse**

Run: `nix flake show 2>&1 | head -40`
Expected: lists all 9 nixosConfigurations (3 full + 3 bootstrap + 3 eval-test). No parse errors.

- [ ] **Step 4: Commit**

```bash
git add hosts/_fixture-hardware.nix flake.nix
git commit -m "feat: fixture-hardware + <host>-eval-test outputs for pre-deploy eval"
```

### Task 22: Generate flake.lock

**Files:**
- Create: `flake.lock` (generated)

- [ ] **Step 1: Run nix flake update**

Run: `nix flake update 2>&1 | tail -10`
Expected: writes flake.lock with the three inputs (nixpkgs, disko, agenix) pinned.

- [ ] **Step 2: Commit**

```bash
git add flake.lock
git commit -m "chore: initial flake.lock"
```

---

## Phase 7 — Helper Scripts

### Task 23: Write bin/new-repo.sh skeleton

**Files:**
- Create: `bin/new-repo.sh`

The script orchestrates per-repo creation across the cluster. It SSHes into canonical and each secondary; passwords are read from each host's local agenix-decrypted file — they never leave the host.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
#
# new-repo.sh <reponame>
#
# Create a new fossil repo on canonical, then clone it onto each secondary,
# wiring the sync user + remote URL.
#
# Hosts are reached over SSH (must be configured: hostname → IP via DNS or
# ~/.ssh/config). The sync password is read from
# /run/agenix/fossil-sync on each host — never embedded in this script.
#
# Usage:
#   bin/new-repo.sh <reponame>

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <reponame>" >&2
  exit 2
fi

REPO="$1"

# Validate the repo name before any SSH work. We use $REPO as both a
# filesystem basename (/var/lib/fossil/museum/$REPO.fossil) and a URL
# path component (https://.../$REPO). Allowed: letters, digits,
# underscore, hyphen. Must start with a letter or digit. No dots
# (fossil treats `.fossil` extension specially), no slashes, no `..`,
# no whitespace.
if ! [[ "$REPO" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
  echo "FATAL: repo name '$REPO' is invalid." >&2
  echo "Allowed: ^[A-Za-z0-9][A-Za-z0-9_-]*\$" >&2
  exit 2
fi

CANONICAL="fossil.exidia.com"
SECONDARIES=("s1.fossil.exidia.com" "s2.fossil.exidia.com")
# Per-host constants (REPO_DIR, SYNC_CRED_FILE, SUDO_AS_FOSSIL) are
# defined inside each remote heredoc — they run on the remote host, not
# locally. Don't hoist them up here; outer-scope copies would be unused
# (single-quoted heredocs don't expand outer variables) and shellcheck
# would flag them as SC2034.

remote() {
  local host="$1"
  shift
  # The remote command receives "$@" verbatim; any "$VAR" inside that
  # argument list expands on the local shell before ssh is invoked.
  # We intentionally rely on that for parameters like the repo name —
  # the heredoc body itself uses 'EOF' (single-quoted) so it does NOT
  # expand locally; only the args to bash -s expand locally.
  # shellcheck disable=SC2029
  ssh "$host" "$@"
}

echo ">>> 1/3 Initializing repo + syncuser on canonical ($CANONICAL)"
remote "$CANONICAL" bash -s -- "$REPO" <<'EOF'
set -euo pipefail
REPO="$1"
REPO_DIR=/var/lib/fossil/museum
SUDO_AS_FOSSIL=(sudo -u fossil env HOME=/var/lib/fossil)
SYNC_CRED_FILE=/run/agenix/fossil-sync

if [[ ! -r "$SYNC_CRED_FILE" ]]; then
  echo "FATAL: $SYNC_CRED_FILE not readable on canonical" >&2
  exit 1
fi
PASS=$(cat "$SYNC_CRED_FILE")

REPO_FILE="$REPO_DIR/$REPO.fossil"
if [[ -e "$REPO_FILE" ]]; then
  echo "FATAL: $REPO_FILE already exists on canonical" >&2
  exit 1
fi

"${SUDO_AS_FOSSIL[@]}" fossil init "$REPO_FILE"
"${SUDO_AS_FOSSIL[@]}" fossil user new syncuser "" "$PASS" -R "$REPO_FILE"
"${SUDO_AS_FOSSIL[@]}" fossil user capabilities syncuser v -R "$REPO_FILE"
"${SUDO_AS_FOSSIL[@]}" fossil all add "$REPO_FILE"
echo "OK canonical: $REPO_FILE initialized; syncuser created."
EOF

for sec in "${SECONDARIES[@]}"; do
  echo ">>> 2/3 Cloning repo onto secondary ($sec)"
  remote "$sec" bash -s -- "$REPO" "$CANONICAL" <<'EOF'
set -euo pipefail
REPO="$1"
CANONICAL="$2"
REPO_DIR=/var/lib/fossil/museum
SUDO_AS_FOSSIL=(sudo -u fossil env HOME=/var/lib/fossil)
SYNC_CRED_FILE=/run/agenix/fossil-sync

if [[ ! -r "$SYNC_CRED_FILE" ]]; then
  echo "FATAL: $SYNC_CRED_FILE not readable on $(hostname)" >&2
  exit 1
fi
PASS=$(cat "$SYNC_CRED_FILE")

REPO_FILE="$REPO_DIR/$REPO.fossil"
if [[ -e "$REPO_FILE" ]]; then
  echo "FATAL: $REPO_FILE already exists on $(hostname)" >&2
  exit 1
fi

"${SUDO_AS_FOSSIL[@]}" fossil clone "https://syncuser:$PASS@$CANONICAL/$REPO" "$REPO_FILE"
"${SUDO_AS_FOSSIL[@]}" fossil remote-url -R "$REPO_FILE" "https://syncuser:$PASS@$CANONICAL/$REPO"
"${SUDO_AS_FOSSIL[@]}" fossil all add "$REPO_FILE"
echo "OK $(hostname): $REPO_FILE cloned."
EOF

  echo ">>> 3/3 Verifying sync from $sec"
  remote "$sec" bash -s -- <<'EOF'
set -euo pipefail
SUDO_AS_FOSSIL=(sudo -u fossil env HOME=/var/lib/fossil)
"${SUDO_AS_FOSSIL[@]}" fossil all sync -u
echo "OK $(hostname): all sync succeeded."
EOF
done

echo
echo "✅ Repo '$REPO' created across cluster."
echo "Next: visit https://$CANONICAL/$REPO/setup/users to set up real users."
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x bin/new-repo.sh
```

- [ ] **Step 3: Run shellcheck**

Run: `nix run nixpkgs#shellcheck -- bin/new-repo.sh`
Expected: no errors. Some informational warnings are acceptable.

- [ ] **Step 4: Commit**

```bash
git add bin/new-repo.sh
git commit -m "feat: bin/new-repo.sh for cluster-wide repo creation"
```

### Task 24: Write bin/smoke-test.sh

**Files:**
- Create: `bin/smoke-test.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
#
# smoke-test.sh <hostname>
#
# Post-deploy verification:
#   - HTTPS GET / returns 200
#   - TLS cert is valid (not expired, matches hostname)
#   - Tailscale reports the host as Online
#   - /timeline.rss exists for at least one known repo (if any)
#
# Usage: bin/smoke-test.sh fossil.exidia.com

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <hostname>" >&2
  exit 2
fi

HOST="$1"
FAIL=0

note() { printf "    %s\n" "$*"; }
pass() { printf "✅  %s\n" "$*"; }
fail() { printf "❌  %s\n" "$*"; FAIL=1; }

echo "Smoke-testing https://$HOST/"

# 1. HTTPS GET / — `-fsS` performs TLS cert validation (trust chain +
# hostname match) and fails on >=400. No `-k`: a self-signed, expired,
# or wrong-hostname cert would fail this check.
status=$(curl -fsS -o /dev/null -w '%{http_code}' "https://$HOST/" 2>/dev/null || echo "curl-failed")
if [[ "$status" =~ ^[23][0-9][0-9]$ ]]; then
  pass "GET / returned $status (TLS validation passed)"
else
  fail "GET / failed: $status (TLS validation may have failed; try \`curl -v https://$HOST/\` to see why)"
fi

# 2. TLS cert not-expired (explicit check). `s_client < /dev/null` plus
# `-checkend 0` exits non-zero if the cert is expired right now.
if echo | openssl s_client -servername "$HOST" -connect "$HOST:443" 2>/dev/null \
    | openssl x509 -noout -checkend 0 >/dev/null 2>&1; then
  expiry=$(echo | openssl s_client -servername "$HOST" -connect "$HOST:443" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null \
    | cut -d= -f2)
  pass "TLS cert not expired (until: $expiry)"
else
  fail "TLS cert is expired or unreachable"
fi

# 3. Tailscale presence (best-effort; skip if tailscale CLI unavailable locally)
if command -v tailscale >/dev/null 2>&1; then
  if tailscale status 2>/dev/null | grep -q -E "^[^[:space:]]+\s+$HOST\b|\b${HOST%%.*}\s"; then
    pass "Tailscale: $HOST visible on tailnet"
  else
    note "Tailscale: $HOST not visible (may be expected if running from non-tailnet machine)"
  fi
else
  note "tailscale CLI not installed locally — skipping tailnet check"
fi

# 4. Fossil-specific endpoint (best-effort)
if curl -sk "https://$HOST/" | grep -qi "fossil"; then
  pass "response body mentions 'fossil'"
else
  note "response body does not mention 'fossil' — verify manually"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo
  echo "FAILED — see ❌ lines above"
  exit 1
fi

echo
echo "✅ All checks passed for $HOST."
```

- [ ] **Step 2: chmod + shellcheck**

```bash
chmod +x bin/smoke-test.sh
nix run nixpkgs#shellcheck -- bin/smoke-test.sh
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add bin/smoke-test.sh
git commit -m "feat: bin/smoke-test.sh for post-deploy verification"
```

---

## Phase 8 — Documentation

Eight files in total (1 README + 4 top-level + 3 runbooks, plus the 2 we deferred from §7 of the spec). Each follows the standards in §7 of the spec: Purpose / Prerequisites / Procedure / Verification / Rollback / Cross-references.

### Task 25: Write README.org

**Files:**
- Create: `README.org`

- [ ] **Step 1: Write README**

```org
#+TITLE: nixos-fossil
#+OPTIONS: toc:2

* Overview

A NixOS-based fossil-server cluster for self-hosting personal projects.
Three hosts (canonical + 2 secondaries) replicate via fossil's built-in
sync. Native TLS, no reverse proxy. Public hosting on GitHub with
agenix-encrypted secrets.

* Hosts

| Hostname           | Role        | Location            |
|--------------------+-------------+---------------------|
| =fossil.exidia.com=    | canonical   | Hetzner DC1         |
| =s1.fossil.exidia.com= | secondary-1 | Hetzner DC2         |
| =s2.fossil.exidia.com= | secondary-2 | DigitalOcean        |

* Quick links

- [[file:docs/architecture.org][Architecture]] — why the system looks this way.
- [[file:docs/setup.org][Setup]] — initial bootstrap, adding a host, adding a repo.
- [[file:docs/operations.org][Operations]] — routine maintenance, auto-upgrade, secrets, monitoring.
- [[file:docs/reference.org][Reference]] — module options, secrets catalog, network topology.
- [[file:docs/runbooks/][Runbooks]] — emergency procedures.

* Local dev

#+begin_src bash
# Evaluate every host's config (some throw on hardware-config placeholder; see docs)
nix flake check

# Evaluate one host
nix eval '.#nixosConfigurations.canonical-bootstrap.config.system.build.toplevel.drvPath' --raw
#+end_src

* License

(none — private project)
```

- [ ] **Step 2: Commit**

```bash
git add README.org
git commit -m "docs: README.org with project overview + quick links"
```

### Task 26: Expand docs/setup.org

**Files:**
- Modify: `docs/setup.org`

- [ ] **Step 1: Replace the file's content**

Replace the entire contents of `docs/setup.org` with:

```org
#+TITLE: Setup
#+OPTIONS: toc:3

This document covers all setup flows: initial bootstrap of the project, adding a new host, and adding a new fossil repo.

* Initial bootstrap

First-time setup of the project. Run once.

** Prerequisites

- Cloudflare account.
- Hetzner Cloud account.
- DigitalOcean account (only when bringing up =secondary-2=).
- Local =age=, =agenix=, =nix=, =ssh=, =curl=, =openssl= installed.
- This repo cloned at =~/dev/my/nixos-fossil=.

** Procedure

*** 1. Register your SSH key as the agenix admin recipient

agenix uses your SSH ed25519 key as both the *recipient* (when encrypting) and the *identity* (when decrypting). It looks for the private half at =~/.ssh/id_ed25519= by default, so no =-i= flag is needed on any =agenix= invocation in this guide.

Print your SSH public key:

#+begin_src bash
cat ~/.ssh/id_ed25519.pub
#+end_src

Edit =secrets/secrets.nix=, replace the =tmk= placeholder string with the full line (=ssh-ed25519 AAAA... user@host=) from your =id_ed25519.pub=:

#+begin_src bash
$EDITOR secrets/secrets.nix
#+end_src

Back up =~/.ssh/id_ed25519= (private half) to 1Password or equivalent. Losing it means losing decrypt access to every secret in the repo until a host with a recipient key can be reached.

*** Note on the zero-byte placeholders

Steps 3-7 below each populate one of the =secrets/*.age= files. The repo
ships these as zero-byte placeholders (committed during implementation
so Nix path literals resolve during =nix eval=). =agenix -e <file>=
treats any existing =<file>= as encrypted age content and tries to
decrypt it before opening the editor — and 0-byte content is not valid
age payload, so =agenix= would error.

**Workaround: for the FIRST encryption of each secret, `rm` the
placeholder immediately before `agenix -e`.** Once a real encrypted
file exists, subsequent rotations use plain =agenix -e= without the
=rm= (the file is now valid encrypted content).

Each step below shows the =rm secrets/<name>.age && agenix -e secrets/<name>.age=
form explicitly.

*** 2. Cloudflare account + DNS-01 API token

In Cloudflare's dashboard:

1. Add the domain =exidia.com= (or use an existing zone if you already do).
2. Create a child zone =fossil.exidia.com=:
   - At Hover, set NS records for =fossil.exidia.com= pointing at Cloudflare's nameservers for that subdomain.
   - Wait for delegation to propagate (=dig NS fossil.exidia.com=).
3. Create an API token at https://dash.cloudflare.com/profile/api-tokens:
   - Permissions: =Zone:DNS:Edit=
   - Zone resources: include only =fossil.exidia.com=
   - Save the generated token securely.

*** 3. Encrypt cloudflare-dns.age

The =security.acme= module reads this as an env file. Format (one line,
no quotes around the value, no trailing newline if your editor lets you
control that):

#+begin_src text
CLOUDFLARE_DNS_API_TOKEN=<paste-the-token-here>
#+end_src

Encrypt it:

#+begin_src bash
cd ~/dev/my/nixos-fossil
rm secrets/cloudflare-dns.age && agenix -e secrets/cloudflare-dns.age
# Editor opens on a temp plaintext file. Type or paste the line above
# (with your real token substituted in). Save and exit. agenix encrypts.
#+end_src

agenix uses =$EDITOR= for the temp file — set it to whatever you prefer
(=export EDITOR=vim= etc.) before running the command.

*** 4. Encrypt the fossil-sync password

This password is embedded into HTTPS URLs by =bin/new-repo.sh= and the rotation runbook (=https://syncuser:$PASS@.../...=), so it MUST be URL-safe — no =@=, =:=, =/=, =%=, =?=, =#=, =+=, or whitespace. =pwgen -s= (the =-s= flag means "completely random, no human-friendly substitutions") produces alphanumeric output which is safe.

Do NOT substitute =openssl rand -base64= or similar — those generate =+/= characters that break URL parsing.

#+begin_src bash
pwgen -s 64 1 > /tmp/sync.pass     # alphanumeric, URL-safe; 64 chars of entropy
rm secrets/fossil-sync.age && agenix -e secrets/fossil-sync.age
# paste contents of /tmp/sync.pass; one line, no trailing newline
rm /tmp/sync.pass
#+end_src

*** 5. Encrypt tmk-password.age

Generate a yescrypt-hashed password (this is the breaking-glass console password):

#+begin_src bash
mkpasswd -m yescrypt    # type a strong password; copy the entire $y$...$ hash
rm secrets/tmk-password.age && agenix -e secrets/tmk-password.age
# paste the hash; one line
#+end_src

*** 6. Create healthchecks.io account + 2 checks

At https://healthchecks.io:

- Create account.
- Create one check per secondary, name them =secondary-1-sync= and =secondary-2-sync=.
- Schedule: =every 5 minutes=, grace =15 minutes=.
- Copy each check's ping URL.

Encrypt the URLs:

#+begin_src bash
rm secrets/healthchecks-secondary-1.age && agenix -e secrets/healthchecks-secondary-1.age
# paste URL, one line
rm secrets/healthchecks-secondary-2.age && agenix -e secrets/healthchecks-secondary-2.age
# paste URL, one line
#+end_src

*** 7. Generate Tailscale auth keys

In Tailscale admin → Keys, create three /tagged/, /one-time/, /pre-approved/, /ephemeral=false/ auth keys; one per host. Tag them e.g. =tag:fossil=.

Encrypt each:

#+begin_src bash
rm secrets/tailscale-authkey-canonical.age && agenix -e secrets/tailscale-authkey-canonical.age
# paste auth key
rm secrets/tailscale-authkey-secondary-1.age && agenix -e secrets/tailscale-authkey-secondary-1.age
rm secrets/tailscale-authkey-secondary-2.age && agenix -e secrets/tailscale-authkey-secondary-2.age
#+end_src

*** 8. Push to GitHub

#+begin_src bash
git add -A
git commit -m "feat: encrypted secrets initialized"
gh repo create teehemkay/nixos-fossil --public --source . --push
# Or: git remote add origin git@github.com:teehemkay/nixos-fossil.git && git push -u origin main
#+end_src

** Verification

- =nix flake check= surfaces only hardware-config placeholder throws (no other errors).
- =secrets/*.age= all show as encrypted text when =cat='d.
- =git status= clean.

* Adding a host

End-to-end procedure for bringing up a new fossil server.

** Prerequisites

- Initial bootstrap complete (you have the admin keypair, Cloudflare token, etc.).
- Provider (Hetzner Cloud or DigitalOcean) account with an SSH key registered.
- This repo on your laptop, in the right directory.

** Procedure

*** 1. Provision the VM

- Hetzner Cloud: create a CPX11 instance in the target DC, attach the NixOS rescue ISO or boot with the recovery image. Capture the IPv4.
- DigitalOcean: similar.

*** 2. DNS A record at Cloudflare

In the =fossil.exidia.com= zone, add an A record for the host:
- =@= for canonical (apex)
- =s1= for secondary-1
- =s2= for secondary-2

*** 3. First boot — bootstrap install via nixos-anywhere

From your laptop:

#+begin_src bash
nixos-anywhere \
  --flake .#<hostname>-bootstrap \
  --target-host root@<ip> \
  --generate-hardware-config nixos-generate-config \
  ./hosts/<hostname>-hardware.nix
#+end_src

Watch for: kexec → install → reboot. After reboot, =ssh root@<ip>= should work using your SSH key.

*** 4. Capture host SSH host pubkey

#+begin_src bash
ssh root@<ip> 'cat /etc/ssh/ssh_host_ed25519_key.pub'
#+end_src

Copy the output (starts with =ssh-ed25519 AAAA...=).

*** 5. Update secrets/secrets.nix + rekey

In =secrets/secrets.nix=, locate the empty list for this host (one of =canonicalHost=, =secondary1Host=, =secondary2Host=) and replace =[ ]= with a one-element list containing the captured pubkey. For example, after provisioning canonical:

#+begin_src nix
# Before:
canonicalHost = [ ];
# After:
canonicalHost = [ "ssh-ed25519 AAAA...captured...pubkey root@canonical" ];
#+end_src

Then re-encrypt every secret whose recipient list includes this host:

#+begin_src bash
agenix --rekey
#+end_src

Commit BOTH the rekey AND the generated hardware-config that =nixos-anywhere= produced in step 4. Without committing the hardware-config, =hosts/<hostname>-hardware.nix= on GitHub remains the throwing placeholder, and =system.autoUpgrade= (which pulls from =github:teehemkay/nixos-fossil#<host>=) will fail to evaluate on the next scheduled run, blocking kernel patches:

#+begin_src bash
git add secrets/ hosts/<hostname>-hardware.nix
git commit -m "feat: register $hostname host key + hardware-config"
git push
#+end_src

*** 6. Promote to full config

#+begin_src bash
nixos-rebuild switch --flake .#<hostname> --target-host root@<ip>
#+end_src

This is the first activation that references agenix secrets. =security.acme= issues the cert. Tailscale joins. fossil-server starts on :443.

*** 7. Smoke test

#+begin_src bash
bin/smoke-test.sh <hostname>.fossil.exidia.com
#+end_src

** Verification

- =bin/smoke-test.sh= all green.
- HTTPS in a browser shows fossil's default page with a valid (non-self-signed) cert.
- =systemctl status fossil-server= on the host shows =active (running)=.
- (Secondaries only) =systemctl list-timers fossil-sync= shows the timer.

** Rollback

If the bootstrap fails partway: re-image the VM and start over from step 3.

If the promote step (#6) fails to activate the new generation: the host stays on the bootstrap config; SSH still works; fix the issue locally and re-run =nixos-rebuild switch=.

* Adding a repo

Cluster-wide creation of a new fossil repo via =bin/new-repo.sh=.

** Prerequisites

- All target hosts deployed and reachable via SSH (configure hostnames in =~/.ssh/config= if needed).
- =/run/agenix/fossil-sync= present and readable on every host (verify with =ssh canonical 'sudo ls -l /run/agenix/fossil-sync'=).

** Procedure

#+begin_src bash
bin/new-repo.sh <reponame>
#+end_src

The script:

1. SSHes to canonical, runs =fossil init=, creates =syncuser= with capability =v=, adds the repo to fossil's =all= list. The sync password is read from =/run/agenix/fossil-sync= on canonical.
2. For each secondary, SSHes in, clones the new repo via =https://syncuser:$PASS@fossil.exidia.com/<name>=, sets =remote-url=, adds to =all=, runs a verifying =fossil all sync -u=.

** Verification

- =bin/new-repo.sh= exits 0.
- Visit =https://fossil.exidia.com/<reponame>/= in a browser — fossil's setup-users page appears.
- After ≤5 min, =https://s1.fossil.exidia.com/<reponame>/= and =https://s2.fossil.exidia.com/<reponame>/= serve the same content.

** Post-creation: bootstrap the admin user

Visit =https://fossil.exidia.com/<reponame>/setup_uedit?user=admin= and set a real password for the admin user (the one fossil created during =fossil init= will have the OS username as login).

** Rollback

If =new-repo.sh= fails partway, remove the partially-created repo file from any hosts that got it:

#+begin_src bash
ssh canonical 'sudo rm /var/lib/fossil/museum/<reponame>.fossil'
ssh s1.fossil.exidia.com 'sudo rm /var/lib/fossil/museum/<reponame>.fossil'
ssh s2.fossil.exidia.com 'sudo rm /var/lib/fossil/museum/<reponame>.fossil'
#+end_src

Then re-run the script.

** Cross-references

- [[file:reference.org#secrets-catalog][Secrets catalog]] for the format/source of =fossil-sync.age=.
- [[file:runbooks/debug-sync-failure.org][debug-sync-failure]] if the verification step fails.
```

- [ ] **Step 2: Commit**

```bash
git add docs/setup.org
git commit -m "docs: setup.org with initial-bootstrap + add-host + add-repo"
```

### Task 27: Write docs/architecture.org

**Files:**
- Create: `docs/architecture.org`

- [ ] **Step 1: Write the file**

```org
#+TITLE: Architecture
#+OPTIONS: toc:2

* Purpose

Explain *why* the cluster is shaped the way it is. Useful when revisiting
a decision after months away.

* Topology

#+begin_src
        ┌───────────────────────┐
        │   fossil.exidia.com   │  ← canonical (Hetzner DC1)
        │     (authoritative)   │
        └───────────┬───────────┘
                    │ pulls + pushes every 5 min
       ┌────────────┼────────────┐
       │            │            │
┌──────▼─────┐ ┌────▼───────┐
│ s1.fossil  │ │ s2.fossil  │  ← secondaries (Hetzner DC2 + DO)
│ .exidia    │ │ .exidia    │     accept user writes locally;
│ .com       │ │ .com       │     converge via canonical
└────────────┘ └────────────┘
#+end_src

Convergence:

- Canonical → secondary: ~5 min worst-case (1 tick).
- Secondary → other secondary: ~10 min worst-case (2 ticks via canonical).

* Decisions and rationale

** Fresh repo vs. extending nixos-anywhere

This is a production deployment with site-specific paths and secrets. The =nixos-anywhere= repo is a fork of the upstream examples repo; keeping it sync-able with upstream is more valuable than cramming a production target into it.

** Fossil-native TLS vs. reverse proxy

Fossil 2.17+ supports native TLS, eliminating the need for nginx/caddy. Native TLS:

- One process instead of two.
- TLS key never enters fossil's chroot (read before privdrop).
- Simpler systemd unit.

** DNS-01 via Cloudflare vs. HTTP-01

DNS-01 lets us close port 80 entirely. HTTP-01 would require a fossil
=--acme= sidecar listener on :80, doubling the process count and
expanding the public surface. The DNS-01 trade-off is migrating
=fossil.exidia.com= to Cloudflare (Hover doesn't expose an API).

** Canonical + secondaries vs. peer mesh

Canonical / secondaries with a single =fossil all sync -u= cron on each
secondary is the documented fossil-scm.org self-host pattern. Simpler
than a full mesh, identical eventual-consistency properties for read/write.

** agenix vs. sops-nix vs. out-of-band

agenix: encrypted secrets in the repo, decrypted by SSH host keys.
Per-deploy bootstrap is one =agenix --rekey= step. Beats out-of-band
(secrets-not-versioned) by a wide margin once you have more than one
host. sops-nix would also work but adds tooling weight.

** Public flake on GitHub vs. private

Encrypted secrets are inert without the corresponding decryption keys.
The public flake makes =system.autoUpgrade= trivially reachable and
doesn't expose anything sensitive.

** healthchecks.io heartbeat vs. SMTP alerts

For "is replication still working?" the dead-man's-switch model
(healthchecks.io pings on success; alert when pings stop) catches more
failure modes than per-failure SMTP, including "host is dead and can't
send mail at all." SMTP-based unit-failure alerts are deferred to a
future iteration if needed.

* Non-goals for v1

- Offsite backups beyond replication.
- Email alerts for arbitrary unit failures.
- Automatic failover / promotion.
- Web UI for repo management.
- NixOS VM integration tests.
- Fossil → Git export mirror.

* Open questions deferred to plan

- Exact fossil capability bits for syncuser (using "v" Developer macro
  as starting point; verify and tighten during early operation).
- Hetzner CPX size: assuming CPX11 is sufficient; revisit if memory pressure.
- DigitalOcean region for secondary-2: pick at provisioning time based
  on geo-diversity from Hetzner DCs.
```

- [ ] **Step 2: Commit**

```bash
git add docs/architecture.org
git commit -m "docs: architecture.org with topology + decisions + non-goals"
```

### Task 28: Write docs/operations.org

**Files:**
- Create: `docs/operations.org`

- [ ] **Step 1: Write the file**

```org
#+TITLE: Operations
#+OPTIONS: toc:3

This document covers day-to-day operations. The expected pace is *low* — the cluster is meant to run unattended.

* Routine checklist

** Weekly

- Glance at the healthchecks.io dashboard. If any check is in "down" or
  "grace" state, jump to [[file:runbooks/debug-sync-failure.org][debug-sync-failure]].

** Monthly

- =ssh canonical 'journalctl -u nixos-upgrade -n 200'= — review the last
  4 autoUpgrade runs. Look for repeated activation failures.
- Repeat for each secondary.

** Quarterly

- Tailscale admin → Keys: verify auth keys haven't expired (they're
  one-time-use so this is mostly a non-issue after install).
- Cloudflare API tokens: check expiry. Rotate per
  [[file:runbooks/rotate-secrets.org][rotate-secrets]] if needed.

** Annually

- Review =stateVersion= in each =hosts/*.nix=. NixOS releases new stable
  channels twice yearly; consider bumping after the next release feels
  stable (~6 months in).

* Auto-upgrade

** How it works

=system.autoUpgrade= installs a systemd timer
(=nixos-upgrade.timer=) that fires =Sun 03:00 UTC=, with a 30-minute
random delay per host so they don't all reboot simultaneously. The
service:

1. =nix flake update= against =github:teehemkay/nixos-fossil#<hostname>=.
2. =nixos-rebuild boot= activates the new generation on next boot.
3. If =allowReboot = true=, reboot now.

If activation fails (or the new generation refuses to boot), NixOS falls
back to the previous generation automatically — the boot menu still has
it.

** Checking upgrade status

#+begin_src bash
ssh <host> 'systemctl status nixos-upgrade.service'
ssh <host> 'journalctl -u nixos-upgrade.service -n 200'
#+end_src

** Manual rollback

#+begin_src bash
ssh <host> 'nixos-rebuild --rollback switch'
#+end_src

Or reboot and pick a previous generation at the boot menu.

** Disabling temporarily

#+begin_src bash
ssh <host> 'sudo systemctl stop nixos-upgrade.timer'
ssh <host> 'sudo systemctl disable nixos-upgrade.timer'
#+end_src

To re-enable: =sudo systemctl enable --now nixos-upgrade.timer=.

* agenix workflow

** Adding a new secret

1. Add the new entry to =secrets/secrets.nix= with the right recipient list.
2. =agenix -e secrets/<name>.age= — paste contents in the editor that opens; save & exit.
3. Reference =config.age.secrets.<name>.path= from the nix module that needs it.
4. Commit + push.
5. On each affected host: =nixos-rebuild switch --flake .#<host> --target-host root@<host>=.

** Rotating an existing secret

#+begin_src bash
agenix -e secrets/<name>.age   # paste new value
git add secrets/<name>.age && git commit -m "chore: rotate <name>"
git push
# Redeploy to every host that consumes this secret:
for host in canonical secondary-1 secondary-2; do
  nixos-rebuild switch --flake .#$host --target-host root@$host
done
#+end_src

Special case: for the fossil-sync password rotation, follow
[[file:runbooks/rotate-secrets.org][rotate-secrets]] for the additional
step of updating each repo's stored remote URL.

** Adding a new host to existing secrets

Add the host's pubkey to =secrets/secrets.nix= recipient list(s), then:

#+begin_src bash
agenix --rekey
git add secrets/ && git commit -m "feat: grant <host> access to <secret(s)>"
#+end_src

** Revoking a host

Remove the host's pubkey from =secrets.nix=, =agenix --rekey=, commit.
Note: the host already has the *decrypted* secret values; this only
prevents future re-encryptions from being readable by it.

* Healthchecks (monitoring)

** What's monitored

Only the secondaries' =fossil-sync.service=:

- =secondary-1-sync= — pings hc.io on every successful sync (every 5 min).
- =secondary-2-sync= — same.

hc.io alerts (via email, configured in hc.io UI) if either stops pinging
for >15 min (the grace period).

** Adding a new check

1. At hc.io: create new check with appropriate schedule + grace.
2. Copy the ping URL.
3. =agenix -e secrets/healthchecks-<name>.age= — paste the URL.
4. In the nix module of the unit you want monitored, add an =ExecStartPost=
   that =curl=s the URL (see =modules/fossil-server.nix= for the pattern).
5. Redeploy.

** Tuning grace periods

In hc.io UI, set grace such that one missed sync isn't an alert (e.g.,
schedule 5min, grace 15min = 3 missed runs before alerting). Network blips
shouldn't page you.
```

- [ ] **Step 2: Commit**

```bash
git add docs/operations.org
git commit -m "docs: operations.org with routine/auto-upgrade/agenix/healthchecks"
```

### Task 29: Write docs/reference.org

**Files:**
- Create: `docs/reference.org`

- [ ] **Step 1: Write the file**

```org
#+TITLE: Reference
#+OPTIONS: toc:3

Lookup material. Open this when you need to remember the exact name or
shape of something — not for narrative explanations (see
[[file:architecture.org][architecture]] for that).

* Module options

** services.fossilServer.*

| Option              | Type                | Default                     | Description                                                                 |
|---------------------+---------------------+-----------------------------+-----------------------------------------------------------------------------|
| =enable=              | bool                | =false=                       | Enable the fossil-server module.                                            |
| =role=                | enum: =canonical= | =secondary= | (required)                  | Cluster role. Only =secondary= runs the sync timer.                          |
| =domain=              | string              | (required)                  | DNS name for ACME + fossil =--baseurl=.                                     |
| =repoDir=             | path                | =/var/lib/fossil/museum=      | Repolist directory holding =.fossil= files.                                   |
| =syncInterval=        | string              | =*:0/5=                       | systemd OnCalendar expression for sync timer.                              |
| =healthcheckUrlFile=  | nullable path       | =null=                        | Path to agenix-decrypted hc.io ping URL. =null= disables monitoring.        |

* Secrets catalog

| File                                          | Purpose                                                 | Format                                                   | Read by                            |
|-----------------------------------------------+---------------------------------------------------------+----------------------------------------------------------+------------------------------------|
| =cloudflare-dns.age=                            | Cloudflare DNS-01 API token                             | Env file: =CLOUDFLARE_DNS_API_TOKEN=<token>=               | =security.acme=                      |
| =fossil-sync.age=                               | Fossil sync user password (cluster-wide)                | Plain text, one line, no trailing newline                | =bin/new-repo.sh=, sync stored URLs |
| =tmk-password.age=                              | tmk's console-fallback yescrypt hash                    | One line =$y$...$=                                         | PAM (via =hashedPasswordFile=)       |
| =tailscale-authkey-<host>.age=                  | Per-host Tailscale auth key (one-time, tagged)          | One line =tskey-auth-...=                                  | =services.tailscale.authKeyFile=     |
| =healthchecks-<host>.age=                       | Per-secondary hc.io ping URL                            | One line =https://hc-ping.com/<uuid>=                      | =fossil-sync.service ExecStartPost=  |

Generation steps for each — see [[file:setup.org][setup.org]].

* Network topology

** DNS

- Registrar: Hover.
- Zone =exidia.com= hosted at Hover.
- Subdomain =fossil.exidia.com= *delegated* to Cloudflare (NS records at Hover point to Cloudflare).
- Cloudflare zone for =fossil.exidia.com= contains:
  - =@= → canonical's IPv4
  - =s1= → secondary-1's IPv4
  - =s2= → secondary-2's IPv4

** Firewall (every host)

| Port  | Proto | Inbound source | Notes                                  |
|-------+-------+----------------+----------------------------------------|
| 22    | TCP   | public + tailnet | SSH (key-only)                       |
| 443   | TCP   | public         | fossil server                          |
| 41641 | UDP   | public         | Tailscale direct-connect (NixOS auto) |
| all   | *     | (outbound)     | default-allow, stateful                |

** Outbound dependencies

Each host needs network access to:

- Cloudflare API (=api.cloudflare.com=) — for DNS-01.
- Let's Encrypt (=acme-v02.api.letsencrypt.org=) — cert issuance.
- =github.com= — for =system.autoUpgrade= flake pull.
- =hc-ping.com= (secondaries only) — for monitoring pings.
- Tailscale coord server (=login.tailscale.com=, =controlplane.tailscale.com=).

** Tailscale

- Tag: =tag:fossil=.
- ACL: defaults are fine for v1 (all members can talk to all members).
- No tailscale-specific firewall rules at the NixOS layer beyond what Tailscale opens.
```

- [ ] **Step 2: Commit**

```bash
git add docs/reference.org
git commit -m "docs: reference.org with module options + secrets catalog + topology"
```

### Task 30: Write docs/runbooks/promote-secondary.org

**Files:**
- Create: `docs/runbooks/promote-secondary.org`

- [ ] **Step 1: Write the runbook**

```org
#+TITLE: Promote a secondary to canonical
#+OPTIONS: toc:2

* Purpose

Canonical is unrecoverable (host dead, data corrupted, account suspended). Promote a healthy secondary to canonical so the cluster keeps serving writes.

This is a *manual* procedure. No automatic failover in v1.

* Prerequisites

- A secondary that's reachable, up-to-date (=fossil all sync -u= recently succeeded), and serving traffic.
- Local access to this repo (=~/dev/my/nixos-fossil=) + Cloudflare API access (web UI or =flarectl=).
- =nixos-rebuild= access to the secondary you're promoting and any *other* surviving secondaries.

* Procedure

** 1. Choose the new canonical

Pick the secondary that's most up-to-date. Verify by SSHing in and running:

#+begin_src bash
sudo -u fossil env HOME=/var/lib/fossil fossil all info | head -40
#+end_src

(Compare =mtime= across hosts if multiple are live.)

** 2. Switch DNS at Cloudflare

In the =fossil.exidia.com= zone, edit the =@= (apex) A record to point at the new canonical's IPv4. TTL was 60 by default; propagation is fast.

#+begin_src bash
# Verify:
dig +short fossil.exidia.com
#+end_src

** 3. Disable the sync timer on the promoted host

The new canonical no longer syncs from itself. Edit =hosts/<promoted>.nix= to change the role:

#+begin_src nix
services.fossilServer = {
  enable = true;
  role = "canonical";   # was "secondary"
  domain = "fossil.exidia.com";   # was e.g. "s1.fossil.exidia.com"
  # remove healthcheckUrlFile
};
#+end_src

**Do NOT change =networking.hostName=** during promotion. The common module derives =system.autoUpgrade.flake= from =config.networking.hostName= (=github:teehemkay/nixos-fossil#${hostName}=). If you rename =secondary-1= to =canonical=, the host will start pulling the =.#canonical= flake output from GitHub on its next weekly autoUpgrade — which is still wired up to the OLD (dead) canonical's config, with its own hardware-config, secrets, and role. Keep the hostname stable; the role change in =services.fossilServer.role= is what makes it the new canonical. The flake output name (=.#secondary-1=) remains the binding identifier.

Commit + push:

#+begin_src bash
git add hosts/<promoted>.nix
git commit -m "feat: promote <promoted> to canonical"
git push
#+end_src

Deploy:

#+begin_src bash
nixos-rebuild switch --flake .#<promoted> --target-host root@<promoted>
#+end_src

This stops =fossil-sync.timer=, re-issues a TLS cert for =fossil.exidia.com= (the new domain), and updates the baseurl.

** 4. Repoint remaining secondaries

If other secondaries are alive, their stored remote URLs point at the *old* canonical's domain (=fossil.exidia.com=) — which now resolves to the new canonical. They should keep working without code changes.

If you also changed the *domain* of the new canonical (you shouldn't, but just in case), re-run =fossil remote-url -R= on every repo on every surviving secondary to point at the new domain.

* Verification

- =dig +short fossil.exidia.com= returns the new canonical's IPv4.
- =bin/smoke-test.sh fossil.exidia.com= passes.
- On each surviving secondary, =sudo systemctl start fossil-sync.service && sudo systemctl status fossil-sync= succeeds.
- =healthchecks.io= pings resume from any remaining secondaries.

* Rollback

If the promotion goes wrong before DNS propagates:

- Revert the Cloudflare A record.
- =git revert= the host config change + redeploy.

If after DNS propagates and writes have happened on the new canonical:

- Decide whether to abandon those writes (revert + accept data loss) or fold them in (treat the new canonical as the new authoritative state).

* Cross-references

- [[file:../setup.org][setup.org]] — adding a fresh host to replace the dead canonical.
- [[file:debug-cert-failure.org][debug-cert-failure]] if the new ACME cert doesn't issue.
```

- [ ] **Step 2: Commit**

```bash
git add docs/runbooks/promote-secondary.org
git commit -m "docs: runbooks/promote-secondary.org"
```

### Task 31: Write docs/runbooks/recover-via-rescue.org

**Files:**
- Create: `docs/runbooks/recover-via-rescue.org`

- [ ] **Step 1: Write the runbook**

```org
#+TITLE: Recover a host via cloud-provider rescue mode
#+OPTIONS: toc:2

* Purpose

You pushed a bad config that broke SSH everywhere (both public and Tailscale). Use the cloud provider's rescue mode to mount the disk and revert.

* Prerequisites

- Provider account access (Hetzner Cloud UI / DigitalOcean UI).
- SSH key registered with the provider.

* Procedure — Hetzner Cloud

** 1. Boot into rescue mode

Hetzner Cloud UI → server → Rescue tab → enable Rescue System (Linux 64-bit) → reboot.

** 2. SSH in as root

Hetzner emails (or shows in UI) a one-time password. Use it.

#+begin_src bash
ssh root@<ip>
#+end_src

** 3. Mount the NixOS root

The disk layout (per =modules/disko.nix=) is GPT → LVM PV → vg "pool" → lv "root".

#+begin_src bash
vgchange -ay pool
mount /dev/pool/root /mnt
mount /dev/sda2 /mnt/boot      # ESP partition
#+end_src

** 4. Roll back the failing generation

Get the boot menu / generation list:

#+begin_src bash
ls -la /mnt/nix/var/nix/profiles/system-*-link
#+end_src

Pick the previous working generation (smaller number = older). For each entry pointing to a generation you want to discard, you can simply mark a previous one as default:

#+begin_src bash
chroot /mnt /run/current-system/sw/bin/nixos-rebuild --rollback boot
#+end_src

(If =chroot= can't find the right binaries, you can also manually delete the broken generation symlink and =nix-env --rollback -p /nix/var/nix/profiles/system=.)

** 5. Disable rescue mode + reboot

In Hetzner UI: disable Rescue System. Then:

#+begin_src bash
umount /mnt/boot /mnt
vgchange -an pool
reboot
#+end_src

** 6. Verify

After the host comes back, =ssh root@<ip>= via your normal SSH key should work. =systemctl --failed= should be empty.

* Procedure — DigitalOcean

** 1. Boot into Recovery ISO

DO UI → droplet → Recovery → Boot from Recovery ISO → reboot.

** 2. SSH in via the droplet console

DO doesn't give SSH access in recovery mode; use the *web console* (DO UI → console).

** 3. Follow steps 3-6 from the Hetzner procedure above.

The disk layout is the same; the only difference is the device path (=/dev/vda= instead of =/dev/sda=).

* Verification

- =ssh <host>= over your normal key succeeds.
- =bin/smoke-test.sh <host>=  passes.

* Cross-references

- This procedure replaces SSH-based recovery — which is broken when public SSH is broken.
- [[file:../operations.org][operations.org]] — for the autoUpgrade rollback procedure that's preferable when SSH still works.
```

- [ ] **Step 2: Commit**

```bash
git add docs/runbooks/recover-via-rescue.org
git commit -m "docs: runbooks/recover-via-rescue.org"
```

### Task 32: Write docs/runbooks/rotate-secrets.org

**Files:**
- Create: `docs/runbooks/rotate-secrets.org`

- [ ] **Step 1: Write the runbook**

```org
#+TITLE: Rotate a secret
#+OPTIONS: toc:2

* Purpose

Rotate one of the agenix-managed secrets (cloudflare-dns / fossil-sync / tailscale auth keys / tmk-password / healthchecks URLs).

* Prerequisites

- Access to the agenix admin keypair.
- Network access to GitHub (for push) and to every host that consumes the secret.

* Common procedure (all secrets)

** 1. Re-encrypt the secret with the new value

#+begin_src bash
cd ~/dev/my/nixos-fossil
agenix -e secrets/<name>.age
# Paste new value; save & exit.
#+end_src

** 2. Commit + push

#+begin_src bash
git add secrets/<name>.age
git commit -m "chore: rotate <name>"
git push
#+end_src

** 3. Redeploy every host that consumes this secret

For most secrets, this means *all three* hosts:

#+begin_src bash
for host in canonical secondary-1 secondary-2; do
  nixos-rebuild switch --flake .#$host --target-host root@$host
done
#+end_src

For per-host secrets (=tailscale-authkey-<host>=, =healthchecks-<host>=), redeploy only that host.

* Per-secret notes

** cloudflare-dns.age

Generate a new token at Cloudflare → My Profile → API Tokens; revoke the old one *after* the new token is deployed and a renewal has succeeded.

** fossil-sync.age — extra steps required, in order

This password is embedded in every secondary's stored remote URL for every repo. Rotating just the agenix secret leaves existing repos using the old password until a manual fix.

**Order matters.** After the common procedure (steps 1-3 above), do these in sequence — the canonical update MUST happen first, otherwise secondaries' new URLs would fail to authenticate against the canonical's still-old password and stop the runbook mid-procedure.

*** Step A: on *canonical*, update each repo's syncuser password

#+begin_src bash
ssh canonical bash -s <<'EOF'
set -euo pipefail
PASS=$(sudo cat /run/agenix/fossil-sync)
SUDO_AS_FOSSIL=(sudo -u fossil env HOME=/var/lib/fossil)

"${SUDO_AS_FOSSIL[@]}" fossil all list | while read -r repo_path; do
  "${SUDO_AS_FOSSIL[@]}" fossil user password syncuser "$PASS" -R "$repo_path"
done
EOF
#+end_src

*** Step B: on *every secondary*, rewrite the remote-url and verify with a manual sync

#+begin_src bash
ssh <secondary> bash -s <<'EOF'
set -euo pipefail
PASS=$(sudo cat /run/agenix/fossil-sync)
SUDO_AS_FOSSIL=(sudo -u fossil env HOME=/var/lib/fossil)

# `fossil all list` outputs one absolute repo path per line.
"${SUDO_AS_FOSSIL[@]}" fossil all list | while read -r repo_path; do
  reponame=$(basename "$repo_path" .fossil)
  "${SUDO_AS_FOSSIL[@]}" fossil remote-url -R "$repo_path" \
    "https://syncuser:$PASS@fossil.exidia.com/$reponame"
done

# Verify with a manual sync — canonical's syncuser password was updated
# in Step A, so this authenticates correctly.
"${SUDO_AS_FOSSIL[@]}" fossil all sync -u -v
EOF
#+end_src

** tailscale-authkey-<host>.age

Auth keys are one-time-use, so rotation only matters if you plan to
*re-provision* the host. The currently-deployed Tailscale daemon is
authenticated independently of the auth key.

** tmk-password.age

Generate with =mkpasswd -m yescrypt= on a trusted machine. Old hash works
until the new one is deployed.

** healthchecks-<host>.age

Regenerate URL at hc.io (delete old check, create new one). The
secondary will start pinging the new URL after redeploy.

* Verification

- =bin/smoke-test.sh <host>= still passes after rotation.
- Manual =fossil all sync -u= on each secondary succeeds (for fossil-sync rotation).
- hc.io dashboard shows pings resuming (for healthchecks rotation).

* Rollback

If the new secret is broken (wrong format, etc.):

- =git revert= the secret commit.
- Redeploy.

* Cross-references

- [[file:../operations.org#agenix-workflow][operations.org → agenix workflow]] for the general pattern.
```

- [ ] **Step 2: Commit**

```bash
git add docs/runbooks/rotate-secrets.org
git commit -m "docs: runbooks/rotate-secrets.org (with per-secret notes)"
```

### Task 33: Write docs/runbooks/debug-cert-failure.org

**Files:**
- Create: `docs/runbooks/debug-cert-failure.org`

- [ ] **Step 1: Write the runbook**

```org
#+TITLE: Debug TLS cert (ACME / DNS-01) failure
#+OPTIONS: toc:2

* Purpose

The =security.acme= module failed to issue or renew a cert. Diagnose and fix.

Symptoms:

- Browser shows "Your connection is not private" / cert expired.
- =bin/smoke-test.sh= fails the "TLS cert valid" check.
- =systemctl status fossil-server= shows the service running but with the old cert.

* Prerequisites

- SSH access to the affected host.
- Cloudflare admin access (web UI).

* Procedure

** 1. Check the ACME unit status

#+begin_src bash
ssh <host> 'systemctl status acme-<domain>.service'
ssh <host> 'journalctl -u acme-<domain>.service -n 200 --no-pager'
#+end_src

Common errors and fixes:

| Error fragment                              | Likely cause                                                                  |
|---------------------------------------------+-------------------------------------------------------------------------------|
| =could not find zone for domain=              | =fossil.exidia.com= is not delegated to Cloudflare. Check NS at Hover.        |
| =authentication failed=                       | Cloudflare API token is wrong/revoked. See [[file:rotate-secrets.org][rotate-secrets]] → cloudflare-dns.       |
| =rate limit exceeded=                         | Let's Encrypt rate-limit hit (5 duplicate certs per week). Wait or use staging. |
| =CLOUDFLARE_DNS_API_TOKEN not set=            | =cloudflare-dns.age= contents not in the expected env-file shape.             |
| =timeout waiting for DNS=                     | DNS-01 record propagation slow. Wait + retry.                                  |

** 2. Inspect the agenix-decrypted credential file

#+begin_src bash
ssh <host> 'sudo cat /run/agenix/cloudflare-dns'
#+end_src

Expected first (only) line: =CLOUDFLARE_DNS_API_TOKEN=<token>=

If the format is wrong (e.g. raw token without the =VAR== prefix),
re-encrypt via [[file:rotate-secrets.org][rotate-secrets]] → cloudflare-dns
and ensure the file is an env file.

** 3. Force an early retry

#+begin_src bash
ssh <host> 'sudo systemctl start acme-<domain>.service'
#+end_src

Watch the journal:

#+begin_src bash
ssh <host> 'sudo journalctl -fu acme-<domain>.service'
#+end_src

** 4. Switch to LE staging for diagnosis (optional)

If you're hitting LE rate limits, add to the affected host config:

#+begin_src nix
security.acme.defaults.server = "https://acme-staging-v02.api.letsencrypt.org/directory";
#+end_src

Deploy, verify cert issues (with fake-LE-CA chain), then remove this line and redeploy for a real cert.

* Verification

- =systemctl status acme-<domain>.service= shows =Result: success=.
- =systemctl status fossil-server.service= reloaded after cert renewal (=reloadServices=).
- =bin/smoke-test.sh <host>= passes the TLS check.
- Browser shows a valid cert.

* Rollback

ACME failures don't break the running fossil-server (it keeps the old cert in memory). There's nothing destructive to rollback. Just leave the broken state until fixed; users get TLS warnings but the service is functionally up.

* Cross-references

- [[file:rotate-secrets.org][rotate-secrets]] for cloudflare-dns.age changes.
- [[file:../setup.org#cloudflare-account-dns-01-api-token][setup.org → Cloudflare token]] for the token-scope requirements.
```

- [ ] **Step 2: Commit**

```bash
git add docs/runbooks/debug-cert-failure.org
git commit -m "docs: runbooks/debug-cert-failure.org"
```

### Task 34: Write docs/runbooks/debug-sync-failure.org

**Files:**
- Create: `docs/runbooks/debug-sync-failure.org`

- [ ] **Step 1: Write the runbook**

```org
#+TITLE: Debug fossil sync failure
#+OPTIONS: toc:2

* Purpose

A secondary's =fossil-sync.service= is failing. healthchecks.io will alert after the grace period, or you noticed during a manual check.

* Prerequisites

- SSH access to the affected secondary + canonical.

* Procedure

** 1. Read the journal

#+begin_src bash
ssh <secondary> 'journalctl -u fossil-sync.service -n 100 --no-pager'
#+end_src

Common errors:

| Error fragment                                     | Likely cause                                                          |
|----------------------------------------------------+-----------------------------------------------------------------------|
| =authentication failed=                             | Sync password mismatch (canonical and secondary). See [[file:rotate-secrets.org][rotate-secrets]] → fossil-sync. |
| =no such user: syncuser=                            | The per-repo syncuser was never created. See [[#new-repo-without-syncuser][below]].             |
| =SSL_connect ... certificate verify failed=         | Canonical's TLS cert is broken. See [[file:debug-cert-failure.org][debug-cert-failure]].                |
| =server returned: 404=                              | Repo doesn't exist on canonical, or remote URL points to the wrong path. |
| =Cannot locate home directory=                      | Fossil =$HOME= not set. Check that =fossil-sync.service= has =User=fossil= and that =users.users.fossil.home= is set. |

** 2. Manual sync with verbose output

#+begin_src bash
ssh <secondary> 'sudo -u fossil env HOME=/var/lib/fossil fossil all sync -u -v'
#+end_src

The =-v= flag prints every repo being synced and what happens for each.

** 3. Verify remote URLs are correct

#+begin_src bash
ssh <secondary> bash -s <<'EOF'
set -euo pipefail
SUDO_AS_FOSSIL=(sudo -u fossil env HOME=/var/lib/fossil)
"${SUDO_AS_FOSSIL[@]}" fossil all list | while read -r repo_path; do
  echo "=== $repo_path ==="
  "${SUDO_AS_FOSSIL[@]}" fossil remote-url -R "$repo_path"
done
EOF
#+end_src

Expected: each line is =https://syncuser:<password>@fossil.exidia.com/<reponame>=. If any URL points elsewhere, fix with =fossil remote-url -R <repo> <url>=.

** <<new-repo-without-syncuser>>4. Repair: syncuser missing on canonical

If the journal said "no such user: syncuser" for a specific repo, the syncuser was never created on canonical for that repo. Fix it:

#+begin_src bash
ssh canonical bash -s <<'EOF'
set -euo pipefail
PASS=$(sudo cat /run/agenix/fossil-sync)
SUDO_AS_FOSSIL=(sudo -u fossil env HOME=/var/lib/fossil)
REPO_FILE=/var/lib/fossil/museum/<repo>.fossil   # ← replace <repo>

"${SUDO_AS_FOSSIL[@]}" fossil user new syncuser "" "$PASS" -R "$REPO_FILE"
"${SUDO_AS_FOSSIL[@]}" fossil user capabilities syncuser v -R "$REPO_FILE"
EOF
#+end_src

** 5. Re-trigger the sync timer

#+begin_src bash
ssh <secondary> 'sudo systemctl start fossil-sync.service'
ssh <secondary> 'sudo systemctl status fossil-sync.service'
#+end_src

* Verification

- =systemctl status fossil-sync.service= shows =Result: success= and recent =Triggers=.
- healthchecks.io pings resume (visible at https://healthchecks.io).
- =fossil all sync -u -v= on the secondary completes with no error per repo.

* Rollback

Sync failures are non-destructive (fossil's append-only model). There's nothing to rollback at the data layer. Just keep retrying after each fix.

* Cross-references

- [[file:rotate-secrets.org][rotate-secrets]] → fossil-sync.
- [[file:debug-cert-failure.org][debug-cert-failure]] if the cause is canonical's TLS.
- [[file:../setup.org#adding-a-repo][setup.org → Adding a repo]] for the right way to provision new repos (so syncuser is always created).
```

- [ ] **Step 2: Commit**

```bash
git add docs/runbooks/debug-sync-failure.org
git commit -m "docs: runbooks/debug-sync-failure.org"
```

---

## Phase 9 — Final Verification & Handoff

### Task 35: Final flake check + per-target eval

**Files:**
- (verification only)

- [ ] **Step 1: Run full nix flake check**

Run: `nix flake check 2>&1 | tail -30`
Expected: hardware-config placeholder throw(s); no other errors. (Per-target eval is the way to confirm each output independently — flake check halts at the first error.)

- [ ] **Step 2: Per-target eval for the 6 throwing outputs (sanity)**

```bash
for target in canonical canonical-bootstrap secondary-1 secondary-1-bootstrap secondary-2 secondary-2-bootstrap; do
  echo "=== $target ==="
  nix eval ".#nixosConfigurations.$target.config.system.build.toplevel.drvPath" --raw 2>&1 | tail -3
  echo ""
done
```

Expected: every target throws "hosts/<name>-hardware.nix is a placeholder". This confirms the throw guard is in place. It does NOT verify the rest of the module wiring — that's the eval-test outputs' job (step 3).

- [ ] **Step 3: Per-target eval for the 3 eval-test outputs (real wiring verification)**

```bash
for target in canonical-eval-test secondary-1-eval-test secondary-2-eval-test; do
  echo "=== $target ==="
  nix eval ".#nixosConfigurations.$target.config.system.build.toplevel.drvPath" --raw 2>&1 | tail -3
  echo ""
done
```

Expected: each prints a `/nix/store/...-nixos-system-...drv` path. No throws, no errors. This is the load-bearing verification: it forces evaluation of every module option, every `config.age.secrets.X.path` reference, the fossil-server service definition, and the sync timer.

If any of these fail with a real error (e.g., "attribute 'cloudflare-dns' missing", "infinite recursion at ...", "the option services.fossilServer.X has no default"), that's a real wiring bug — investigate before proceeding.

Note: agenix `.age` files must *exist* (as on-disk paths) during eval because Nix forces path literals when building the derivation. They do NOT need real encrypted *content* — agenix only reads content at activation time. Task 3 committed zero-byte placeholders, which is exactly what eval needs.

- [ ] **Step 3: Run shellcheck on all scripts**

Run: `nix run nixpkgs#shellcheck -- bin/new-repo.sh bin/smoke-test.sh`
Expected: no errors.

- [ ] **Step 4: Final commit (if any)**

If anything broke during this verification, fix it and commit. Otherwise nothing to commit.

### Task 36: Push to GitHub

**Files:**
- (none changed; remote operation)

- [ ] **Step 1: Push**

```bash
git push origin main
```

Expected: clean push. =github:teehemkay/nixos-fossil= now serves the full repo (used by =system.autoUpgrade=).

### Task 37: Document the plan completion + handoff to deploy

**Files:**
- (none changed; conversation)

- [ ] **Step 1: Inform tmk**

At this point the code is complete and verifies cleanly. The next step is *deployment*, which is operational rather than implementation:

1. Follow `docs/setup.org` § "Initial bootstrap" once.
2. Follow `docs/setup.org` § "Adding a host" for canonical, then secondary-1.
3. (Defer secondary-2 until you've decided on a DigitalOcean region.)
4. Follow `docs/setup.org` § "Adding a repo" to create your first fossil repo.

Acceptance criteria from spec §8:

1. ✓ `nix flake check` evaluates cleanly (allowing hardware-config throws).
2. ✓ Per-target eval succeeds (throws on placeholder, no other errors).
3. (Deploy-time) `nixos-anywhere` bootstraps a fresh host.
4. (Deploy-time) Sync timer succeeds; convergence per spec.
5. (Deploy-time) TLS certs issued.
6. (Deploy-time) SSH works.
7. (Deploy-time) Console password unlocks tmk's account.
8. ✓ Documentation in §7 written.
9. ✓ `bin/smoke-test.sh` and `bin/new-repo.sh` exist and shellcheck-clean.

Items 3-7 are validated by following the runbooks in `docs/setup.org`. The plan's responsibility ends here.

---

## Definition of Done

- [ ] All 38 tasks complete (incl. Task 21b).
- [ ] `nix flake check` produces only the expected hardware-config throws.
- [ ] Per-target eval for the 6 throwing outputs (`<host>` + `<host>-bootstrap`) throws as expected.
- [ ] Per-target eval for the 3 eval-test outputs (`<host>-eval-test`) succeeds — no real wiring errors.
- [ ] `bin/new-repo.sh` validates its repo-name argument and is shellcheck-clean.
- [ ] `bin/smoke-test.sh` shellcheck-clean.
- [ ] All 10 documentation files exist (README + 4 top-level + 5 runbooks) and follow the §7 standard.
- [ ] All work committed and pushed to `github:teehemkay/nixos-fossil`.
- [ ] tmk has the green light to start the deploy procedure in `docs/setup.org`.
