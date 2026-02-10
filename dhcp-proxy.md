# Convert PXE Boot to DHCP Proxy Mode

## Rationale

`hosts/mtworx/configuration.nix` currently runs dnsmasq as a full DHCP server
on an isolated bridge (`br0`, `10.14.143.0/24`) with NAT to WiFi. The IP
`10.14.143.1` is hardcoded in 14+ places: dnsmasq config, iPXE embedded menu,
NFS exports, firewall rules, and NAT config.

This is a laptop. When connecting to different networks, the server IP changes.
The current setup only works on the hardcoded `10.14.143.0/24` bridge network.

Converting to **proxyDHCP** mode allows the laptop to PXE-boot clients on any
existing network: dnsmasq won't allocate IPs (the existing DHCP server does
that), it only responds to PXE broadcast requests with TFTP boot info.

---

## Implementation

### 1. dnsmasq: switch to proxy mode

**Change `dhcp-range` to proxy mode** (`configuration.nix:345-368`):

```nix
# BEFORE:
dnsmasq.settings = {
  dhcp-range = [ "10.14.143.100,10.14.143.200" ];
  dhcp-option = "66,\"0.0.0.0\"";
  enable-tftp = true;
  tftp-root = "${tftp-root}";
  interface = "br0";
  # ...
};

# AFTER:
dnsmasq.settings = {
  dhcp-range = [ "0.0.0.0,proxy" ];
  # dhcp-option 66 removed — proxy mode auto-sets next-server to dnsmasq's own IP
  enable-tftp = true;
  tftp-root = "${tftp-root}";
  bind-dynamic = true;  # handle interfaces appearing/disappearing on a laptop
  # interface removed or set to the specific LAN interface if needed

  dhcp-match = [
    "set:efi-x86_64,option:client-arch,7"
    "set:efi-x86_64,option:client-arch,9"
    "set:efi-x86,option:client-arch,6"
    "set:bios,option:client-arch,0"
  ];

  dhcp-boot = [
    "tag:efi-x86_64,boot.efi"
    "tag:efi-x86,boot.efi"
    "tag:bios,boot.kpxe"
    "boot.efi"
  ];
};
```

**Why this works:**
- `0.0.0.0` in `dhcp-range` means "the address of the machine running dnsmasq."
  dnsmasq auto-detects its own IP for the next-server (siaddr) field in DHCP responses.
- Proxy mode means dnsmasq does NOT allocate IPs — the existing network's DHCP
  server handles that. dnsmasq only adds PXE boot options to the DHCP exchange.
- `bind-dynamic` allows dnsmasq to cope with network interfaces appearing and
  disappearing (useful on a laptop that connects/disconnects from networks).
- `dhcp-option=66` is removed because proxy mode automatically sets the
  next-server field to dnsmasq's own IP address.

### 2. iPXE URLs: use `${next-server}` variable

**Replace all hardcoded `10.14.143.1` with iPXE's `${next-server}`**
(`configuration.nix:11-83`):

iPXE populates `${next-server}` from the DHCP/proxyDHCP response (the siaddr
field). Since dnsmasq in proxy mode sets this to its own IP, the variable
will contain the correct server address at boot time.

iPXE expands **all** `${}` variables in `kernel` and `initrd` command lines
before passing arguments to the kernel. This means kernel-level params like
`nfsroot=` and `fetch=` also get the correctly substituted IP. The existing
script already uses `''${cmdline}` and `''${platform}` as iPXE variables,
confirming this substitution mechanism works.

```nix
# BEFORE (every kernel/initrd line):
kernel http://10.14.143.1/boot/debian-xfce/live/vmlinuz boot=live components fetch=http://10.14.143.1/boot/debian-xfce/live/filesystem.squashfs ...
initrd http://10.14.143.1/boot/debian-xfce/live/initrd.img

# AFTER:
kernel http://''${next-server}/boot/debian-xfce/live/vmlinuz boot=live components fetch=http://''${next-server}/boot/debian-xfce/live/filesystem.squashfs ...
initrd http://''${next-server}/boot/debian-xfce/live/initrd.img
```

Apply the same substitution to all boot menu entries:
- `:debian-shell-toram` — `kernel` and `initrd` URLs, plus `fetch=` param
- `:debian-shell-nfs` — `kernel` and `initrd` URLs, plus `nfsroot=` param
- `:debian-xfce-toram` — `kernel` and `initrd` URLs, plus `fetch=` param
- `:debian-xfce-nfs` — `kernel` and `initrd` URLs, plus `nfsroot=` param
- `:nixos` — `kernel` and `initrd` URLs
- `:alpine` — `kernel` and `initrd` URLs

In Nix string syntax, `${next-server}` must be escaped as `''${next-server}`
to prevent Nix from interpreting it as a Nix interpolation (same as the
existing `''${cmdline}` usage).

### 3. NFS exports

**Change** (`configuration.nix:95-97`):

```nix
# BEFORE:
exportsFile = pkgs.writeText "unfs3-exports" ''
  /boot 10.14.143.0/24(ro,no_subtree_check,no_root_squash,insecure) localhost(ro,...)
'';

# AFTER:
exportsFile = pkgs.writeText "unfs3-exports" ''
  /boot *(ro,no_subtree_check,no_root_squash,insecure)
'';
```

Exporting to `*` allows any client on whatever network the laptop is currently
on. The firewall (see below) provides access control. The NFS share is
read-only boot images, so the security impact is minimal.

### 4. Remove bridge and NAT

**Remove the br0 bridge** (`configuration.nix:392-411`):

The bridge was needed to create an isolated network. In proxy mode, PXE clients
are on the same network as the laptop. Remove:

```nix
# REMOVE these sections:
bridges.br0 = { interfaces = [ ]; };
interfaces.br0 = { ipv4.addresses = [{ address = "10.14.143.1"; prefixLength = 24; }]; };
nat = { enable = true; externalInterface = "wlp0s20f3"; internalInterfaces = [ "br0" ]; internalIPs = [ "10.14.143.0/24" ]; };
```

### 5. Firewall

**Simplify firewall** (`configuration.nix:413-441`):

Remove the `br0`-specific and `10.14.143.0/24`-specific rules. Replace with
port openings on the default interface (or all interfaces):

```nix
# BEFORE:
firewall = {
  rejectPackets = true;
  interfaces.br0 = { allowedTCPPorts = [ 53 80 111 2049 20048 ]; allowedUDPPorts = [ 53 67 69 111 20048 ]; };
  extraCommands = ''
    iptables -A FORWARD -s 10.14.143.0/24 -o wlp0s20f3 -j ACCEPT
    iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A FORWARD -s 10.14.143.0/24 -j DROP
  '';
};

# AFTER:
firewall = {
  rejectPackets = true;
  allowedTCPPorts = [ 80 ];       # HTTP for boot files
  allowedUDPPorts = [ 67 69 ];    # DHCP (proxy) + TFTP
  # NFS ports (111, 2049, 20048) only if NFS boot is still needed:
  # allowedTCPPorts = [ 80 111 2049 20048 ];
  # allowedUDPPorts = [ 67 69 111 20048 ];
  # No forwarding rules needed — clients are on the same network
};
```

Note: opening these ports on all interfaces means any device on the same
network can access the boot server. This is intentional for a PXE proxy.
If you want to restrict to a specific interface, use
`interfaces.<ifname>.allowedTCPPorts` instead.

---

## Files to modify

All changes are in `hosts/mtworx/configuration.nix`:

| Lines | What | Change |
|-------|------|--------|
| 11-83 | iPXE menu (`ipxeMenu`) | Replace `10.14.143.1` with `''${next-server}` (12 occurrences) |
| 95-97 | NFS exports (`exportsFile`) | Change `10.14.143.0/24` to `*` |
| 345-368 | dnsmasq settings | `dhcp-range` to `"0.0.0.0,proxy"`, remove `dhcp-option`, remove/change `interface`, add `bind-dynamic` |
| 392-404 | Bridge + static IP | Remove `bridges.br0` and `interfaces.br0` |
| 406-411 | NAT | Remove entire `nat` block |
| 413-441 | Firewall | Remove `interfaces.br0` scoping and `extraCommands`, open ports globally |

---

## Testing

1. **Build the NixOS configuration:**
   ```
   nix build .#nixosConfigurations.mtworx.config.system.build.toplevel
   ```
   This validates the Nix expression evaluates without errors.

2. **Inspect the iPXE binary:**
   After building, check that `${next-server}` appears in the embedded script:
   ```
   strings result/... | grep next-server
   ```
   (The exact path depends on where the iPXE binary ends up in the store.)

3. **Test on a real network:**
   - Connect the laptop and a PXE client to the same network (e.g., via an
     Ethernet switch or USB Ethernet adapter).
   - Activate the new configuration: `sudo nixos-rebuild switch`
   - PXE boot the client. It should:
     a. Get an IP from the existing DHCP server on the network.
     b. Get PXE boot info (boot filename + TFTP server) from dnsmasq's
        proxyDHCP response.
     c. TFTP-download `boot.efi` or `boot.kpxe` from the laptop.
     d. Display the iPXE menu.
     e. Successfully boot any menu entry (kernel/initrd URLs should resolve
        to the laptop's current IP).

4. **Test NFS boot entries** (if NFS exports are kept):
   - Select "Debian Shell via NFS" or "Debian XFCE via NFS" from the menu.
   - Verify the NFS mount succeeds with the dynamically resolved IP.

5. **Test on a different network:**
   - Move the laptop to a different subnet.
   - Repeat step 3 — the same configuration should work without changes.
