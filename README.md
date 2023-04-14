Config
------

This is an attempt to configure my NixOS servers with [krops][1]. Usage:

    $ direnv allow .
    $ nix-build ./krops.nix -A hel1a && ./result

There is probably nothing to look at here.

Upcoming flakes:

    $ nix build .#deploy.nodes.hel1-a.profiles.system.path

VM:

    $ nix build .#nixosConfigurations.vm.config.system.build.vm

Encoding host-only secrets
--------------------------

Encode a secret on host:

    rage -e -r "$(cat /etc/ssh/ssh_host_ed25519_key.pub)" -o secret.age /path/to/plaintext

Decode a secret on host (to test things out):

    rage -d -i /etc/ssh/ssh_host_ed25519_key secret.age

Bootstrapping
-------------

Prereqs:

    mkdir -p /etc/secrets/initrd
    ssh-keygen -t ed25519 -f /etc/secrets/initrd/ssh_host_ed25519

[1]: https://cgit.krebsco.de/krops/about/

