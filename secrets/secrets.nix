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
#      `agenix -e secrets/<name>.age -i ~/.ssh/id_ed25519_ext` (the file
#      now holds valid age content that agenix must decrypt first, and
#      the admin key sits at a non-default path).
#   3. After each host's bootstrap install, capture its host pubkey from
#      /etc/ssh/ssh_host_ed25519_key.pub. Set the corresponding list
#      below to [ "ssh-ed25519 AAAA... root@<host>" ]. Run
#      `agenix --rekey -i ~/.ssh/id_ed25519_ext` to re-encrypt every
#      affected secret so the new host can read it.
let
  # Admin: tmk's SSH ed25519 public key. agenix accepts SSH ed25519
  # keys as age recipients. The matching private half lives at
  # ~/.ssh/id_ed25519_ext — a non-default path — so every agenix
  # invocation that decrypts (-e, -d, --rekey) must pass
  # `-i ~/.ssh/id_ed25519_ext`; agenix only auto-discovers
  # ~/.ssh/id_ed25519 and ~/.ssh/id_rsa. Print this key with
  # `cat ~/.ssh/id_ed25519_ext.pub`.
  tmk = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKILtMsWYC08UX9hLc5OZaq14vXEn6dImCQH+exaptNw tmk@ext";

  # Host SSH host pubkeys, as lists. Empty until each host is provisioned.
  # After provisioning, set to [ "ssh-ed25519 AAAA... root@<host>" ] then
  # run `agenix --rekey`.
  canonicalHost = [ ]; # e.g. [ "ssh-ed25519 AAAA... root@canonical" ]
  secondary1Host = [ ];
  secondary2Host = [ ];

  allHosts = canonicalHost ++ secondary1Host ++ secondary2Host;
in
{
  # Fossil sync user password: secondaries embed it in repo remote URLs;
  # canonical needs it to create the per-repo syncuser via bin/new-repo.sh.
  "fossil-sync.age".publicKeys = [ tmk ] ++ allHosts;

  # tmk's console-fallback password (breaking-glass only).
  "tmk-password.age".publicKeys = [ tmk ] ++ allHosts;

  # Tailscale auth keys: one per host, only that host decrypts.
  "tailscale-authkey-canonical.age".publicKeys = [ tmk ] ++ canonicalHost;
  "tailscale-authkey-secondary-1.age".publicKeys = [ tmk ] ++ secondary1Host;
  "tailscale-authkey-secondary-2.age".publicKeys = [ tmk ] ++ secondary2Host;

  # healthchecks.io ping URLs: only secondaries need them.
  "healthchecks-secondary-1.age".publicKeys = [ tmk ] ++ secondary1Host;
  "healthchecks-secondary-2.age".publicKeys = [ tmk ] ++ secondary2Host;
}
