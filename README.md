Config
------


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
