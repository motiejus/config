Config
------

This is an attempt to configure my NixOS servers with [krops][1]. Usage:

    $ direnv allow .
    $ nix-build ./krops.nix -A hel1a && ./result

There is probably nothing to look at here.

Upcoming flakes:

    $ nix build .#deploy.nodes.hel1-a.profiles.system.path

Managing secrets
----------------

Encode a secret on host:

    rage -e -r $(ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub) -o secret.age /etc/plaintext

Decode a secret on host (to test things out):

    age -d -i <(sudo ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key) secret.age

If/when [str4d/rage#379](https://github.com/str4d/rage/issues/379) is fixed, we
can replace the above command to `rage`.

[1]: https://cgit.krebsco.de/krops/about/
