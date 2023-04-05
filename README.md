Config
------

This is an attempt to configure my NixOS servers with [krops][1]. Usage:

    $ direnv allow .
    $ nix-build ./krops.nix -A hel1a && ./result

There is probably nothing to look at here.

Upcoming flakes:

    $ nix build .#deploy.nodes.hel1-a.profiles.system.path

[1]: https://cgit.krebsco.de/krops/about/
