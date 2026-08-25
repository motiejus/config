Config
------

Timelapse archive
-----------------

`catalog.json` is atomically exposed after every complete input range: a
monthly source pair is one range, and otherwise each dated daily pair is one
range (there is no within-month splitting). Input range files are final and
immutable. The publisher builds each range below a hidden name, atomically
renames it to `ranges/<range>`, and only then replaces the catalog. Existing
ranges therefore do no media work.

A run starts from the visible catalog: each completed range replaces only its
own entry, so later old entries remain usable if a later new range fails. New
ranges appear only when complete. When a monthly pair supersedes daily pairs,
their catalog entries are replaced in the monthly catalog swap and the daily
ranges and inputs are removed afterward. Complete legacy artifacts are
hard-linked into their range once without re-encoding. A fully successful run
drops stale catalog entries and legacy root artifacts; failed runs retain any
legacy paths still referenced by the catalog. While the first range of a fresh
archive is building, the viewer retries a missing catalog instead of showing
an error.

Flakes:

    $ deploy --interactive '#fwminex'

    $ nix build .#deploy.nodes.fra1-c.profiles.system.path

Other:

    $ nix build .#nixosConfigurations.vno3-rp3b.config.system.build.toplevel
    $ nix eval .#nixosConfigurations.fwminex.config.services.nsd
    $ nix why-depends .#nixosConfigurations.vno1-gdrx.config.system.build.toplevel .#legacyPackages.x86_64-linux.mbedtls_2

git
---

Repos live in `/var/lib/git/<org>/<name>.git`, browsed with stagit-ng at
<https://git.jakstys.lt>. Create-on-push (path must be two-level `<org>/<name>`):

    git remote add origin git@git.jakstys.lt:newrepo.git && git push origin master

Set description with a push option (persisted, shown on the index):

    git push -o description="Short description" origin master

Create a sha256 repo:

    GIT_DEFAULT_HASH=sha256 git push origin master

Rebuild `repositories.txt`: `sudo -u git git-repolist-gen`

Reinstall hooks + regen all: `for r in /var/lib/git/motiejus/*.git; do sudo -u git git-new-repo "motiejus/$(basename "$r" .git)"; done`

Encoding host-only secrets
--------------------------

Encode a secret on host:

    rage -e -r "$(cat /etc/ssh/ssh_host_ed25519_key.pub)" -o secret.age /path/to/plaintext

Decode a secret on host (to test things out):

    rage -d -i /etc/ssh/ssh_host_ed25519_key secret.age

Borg
----

On vno1 coding-agent sandboxes, `borg` is a thin SSH transport with only the
dedicated reader key and strict system host verification; Borg executes on
vno3, which supplies the fwminex passphrase inside the forced reader gate.
List the available hourly snapshots, choose one, then use Borg:

    $BORG_RSH borgstor@vno3-nk.jakst.vpn ls
    export BORG_REPO=/data/.btrfs/btrfs-auto-snap_hourly_YYYY-MM-DD-HH00/borg/fwminex.jakst.vpn-var_lib
    borg --bypass-lock list

The other repository suffix is `fwminex.jakst.vpn-home-motiejus-annex2`.
The server exposes only snapshots and enforces read-only access.
SSH exec framing cannot preserve whitespace within one Borg argument, so paths,
patterns, and other arguments containing whitespace do not work. Export a
broader archive or subtree as tar to stdout, then select or extract locally:

    borg --bypass-lock export-tar ARCHIVE - | tar -x

For arguments without whitespace, downloads can use
`borg --bypass-lock extract --stdout ARCHIVE PATH >file`; plain `extract`
writes only to the reader session's ephemeral remote `/tmp`.

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
