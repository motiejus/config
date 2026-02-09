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
```

efi:

```
qemu-system-x86_64 \
    -enable-kvm \
    -cpu host \
    -m 1024 \
    -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
    -device e1000,netdev=net0 \
    -boot order=n \
    -bios $(nix build .#nixosConfigurations.mtworx.pkgs.OVMF.fd --no-link --print-out-paths)/FV/OVMF.fd
```

bios:

```
qemu-system-x86_64 \
    -enable-kvm \
    -cpu host \
    -m 8192 \
    -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
    -device e1000,netdev=net0 \
    -boot order=n
```
