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
