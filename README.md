Config
------

Flakes:

    $ deploy --interactive '#vno1-oh2'

    $ nix build .#deploy.nodes.hel1-a.profiles.system.path

Other:

    $ nix build .#nixosConfigurations.vno1-rp3b.config.system.build.toplevel

Debug

    $ nix eval .#nixosConfigurations.vno1-oh2.config.services.nsd

Encoding host-only secrets
--------------------------

Encode a secret on host:

    rage -e -r "$(cat /etc/ssh/ssh_host_ed25519_key.pub)" -o secret.age /path/to/plaintext

Decode a secret on host (to test things out):

    rage -d -i /etc/ssh/ssh_host_ed25519_key secret.age
