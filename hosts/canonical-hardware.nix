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
