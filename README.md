Config
------

Flakes:

    $ deploy --interactive '#fwminex'

    $ nix build .#deploy.nodes.fra1-c.profiles.system.path

Other:

    $ nix build .#nixosConfigurations.vno3-rp3b.config.system.build.toplevel
    $ nix eval .#nixosConfigurations.fwminex.config.services.nsd
    $ nix why-depends .#nixosConfigurations.vno1-gdrx.config.system.build.toplevel .#legacyPackages.x86_64-linux.mbedtls_2

Encoding host-only secrets
--------------------------

Encode a secret on host:

    rage -e -r "$(cat /etc/ssh/ssh_host_ed25519_key.pub)" -o secret.age /path/to/plaintext

Decode a secret on host (to test things out):

    rage -d -i /etc/ssh/ssh_host_ed25519_key secret.age

Borg
----

    BORG_PASSCOMMAND="cat /run/agenix/borgbackup-fwminex" borg --remote-path=borg1 list zh2769@zh2769.rsync.net:fwminex.jakst.vpn-home-motiejus-annex2
