Config
------

Flakes:

    $ deploy --interactive '#fwminex'

    $ nix build .#deploy.nodes.fra1-c.profiles.system.path

Other:

    $ nix build .#nixosConfigurations.vno3-rp3b.config.system.build.toplevel
    $ nix eval .#nixosConfigurations.fwminex.config.services.nsd
    $ nix why-depends .#nixosConfigurations.vno1-gdrx.config.system.build.toplevel .#legacyPackages.x86_64-linux.mbedtls_2

git
-------

Create a new repo:

    ssh fwminex 'sudo -u git git-new-repo motiejus/newrepo "Short description"'

Install hook and regenerate all repos:

    for r in /var/lib/git/motiejus/*.git; do sudo -u git git-new-repo "motiejus/$(basename "$r" .git)"; done
    for r in /var/lib/git/motiejus/*.git; do (cd "$r" && sudo -u git hooks/post-receive); done

Wipe stagit cache and regenerate all repos from scratch:

    sudo rm -rf /var/www/git.jakstys.lt/.cache /var/www/git.jakstys.lt/motiejus/*/commit /var/www/git.jakstys.lt/motiejus/*/blob /var/www/git.jakstys.lt/motiejus/*/tree /var/www/git.jakstys.lt/motiejus/*/raw
    for r in /var/lib/git/motiejus/*.git; do (cd "$r" && sudo -u git hooks/post-receive); done

Encoding host-only secrets
--------------------------

Encode a secret on host:

    rage -e -r "$(cat /etc/ssh/ssh_host_ed25519_key.pub)" -o secret.age /path/to/plaintext

Decode a secret on host (to test things out):

    rage -d -i /etc/ssh/ssh_host_ed25519_key secret.age

Borg
----

    BORG_PASSCOMMAND="cat /run/agenix/borgbackup-fwminex" borg --remote-path=borg1 list zh2769@zh2769.rsync.net:fwminex.jakst.vpn-home-motiejus-annex2

netboot
-------

1. `dmesg | grep enp0` <- find the usb interface
2. Disable power saving: `echo -1 | sudo tee /sys/bus/usb/devices/2-1/power/autosuspend`.

Testing netboot
---------------

```
sudo ip tuntap add dev tap0 mode tap user "$USER"
sudo ip link set dev tap0 up
sudo ip link set dev tap0 master br0
sudo brctl addif br0 tap0
```

efi:

```
qemu-system-x86_64 \
    -enable-kvm \
    -cpu host \
    -smp 4 \
    -m 1024 \
    -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
    -device e1000,netdev=net0 \
    -boot order=n \
    -bios $(nix build .#nixosConfigurations.vno1-gdrx.pkgs.OVMF.fd --no-link --print-out-paths)/FV/OVMF.fd
```

bios:

```
qemu-system-x86_64 \
    -enable-kvm \
    -cpu host \
    -smp 4 \
    -m 8192 \
    -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
    -device e1000,netdev=net0 \
    -boot order=n
```
