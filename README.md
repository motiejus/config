Config
------

Flakes:

    $ deploy --interactive '#fwminex'

    $ nix build .#deploy.nodes.fra1-b.profiles.system.path

Other:

    $ nix build .#nixosConfigurations.vno3-rp3b.config.system.build.toplevel
    $ nix eval .#nixosConfigurations.fwminex.config.services.nsd

Encoding host-only secrets
--------------------------

Encode a secret on host:

    rage -e -r "$(cat /etc/ssh/ssh_host_ed25519_key.pub)" -o secret.age /path/to/plaintext

Decode a secret on host (to test things out):

    rage -d -i /etc/ssh/ssh_host_ed25519_key secret.age

Borg
----

    BORG_PASSCOMMAND="cat /run/agenix/borgbackup-fwminex" borg --remote-path=borg1 list zh2769@zh2769.rsync.net:fwminex.servers.jakst-home-motiejus-annex2
