Config
------

Flakes:

    $ deploy --interactive '#vno1-oh2'

    $ nix build .#deploy.nodes.hel1-a.profiles.system.path

VM:

    $ nix build .#nixosConfigurations.vm.config.system.build.vm

Encoding host-only secrets
--------------------------

Encode a secret on host:

    rage -e -r "$(cat /etc/ssh/ssh_host_ed25519_key.pub)" -o secret.age /path/to/plaintext

Decode a secret on host (to test things out):

    rage -d -i /etc/ssh/ssh_host_ed25519_key secret.age
