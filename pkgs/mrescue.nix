{
  lib,
  runCommand,
  makeInitrdNG,
  uutils-coreutils-noprefix,
  bash,
  util-linux,
  e2fsprogs,
  dosfstools,
  parted,
  vim-full,
  findutils,
  gnugrep,
  procps,
  less,
  writeScript,
  kmod,
  linuxPackages_latest,
  linux-firmware,
}:

let
  # Simple init script
  init = writeScript "init" ''
    #!${bash}/bin/bash
    set -e

    # Mount essential filesystems
    ${util-linux}/bin/mount -t proc proc /proc
    ${util-linux}/bin/mount -t sysfs sys /sys
    ${util-linux}/bin/mount -t devtmpfs dev /dev

    # Set up environment
    export PATH=/bin
    export HOME=/root
    export TERM=linux

    # Load essential kernel modules for hardware support
    echo "Loading kernel modules..."
    ${kmod}/bin/modprobe -a \
      nvme sd_mod usb_storage ata_piix ahci \
      ext4 vfat btrfs xfs \
      e1000e igb r8169 virtio_net \
      virtio_blk virtio_scsi \
      >/dev/null 2>&1 || true

    # Display welcome message
    echo ""
    echo "==============================="
    echo "   Rescue System"
    echo "==============================="
    echo ""
    echo "Available utilities:"
    echo "  Shell: bash"
    echo "  Files: ls, cat, less, cp, mv, rm, mkdir (uutils-coreutils)"
    echo "  Disk: mount, fdisk, parted, mkfs.ext4, mkfs.vfat, blkid"
    echo "  Text: vim, grep, find, head, tail"
    echo "  System: ps, kill, chmod, chown"
    echo ""
    echo "Kernel modules and firmware included."
    echo "Type 'exit' or Ctrl+D to reboot"
    echo ""

    # Drop to rescue shell
    exec ${bash}/bin/bash
  '';

  # Package binaries to include
  packageBinaries = [
    # uutils-coreutils (core utilities)
    {
      pkg = uutils-coreutils-noprefix;
      bins = [
        "ls"
        "cat"
        "cp"
        "mv"
        "rm"
        "mkdir"
        "rmdir"
        "chmod"
        "chown"
        "ln"
        "touch"
        "head"
        "tail"
        "dd"
        "echo"
        "pwd"
        "true"
        "false"
      ];
    }
    # bash (shell)
    {
      pkg = bash;
      bins = [
        "bash"
        "sh"
      ];
    }
    # util-linux (mount, disk utilities)
    {
      pkg = util-linux;
      bins = [
        "mount"
        "umount"
        "fdisk"
        "blkid"
        "mkswap"
        "lsblk"
      ];
    }
    # e2fsprogs (ext filesystem tools)
    {
      pkg = e2fsprogs;
      bins = [
        "mkfs.ext4"
        "e2fsck"
        "resize2fs"
      ];
    }
    # dosfstools (FAT filesystem tools)
    {
      pkg = dosfstools;
      bins = [
        "mkfs.vfat"
        "fsck.vfat"
      ];
    }
    # parted (partitioning tool)
    {
      pkg = parted;
      bins = [ "parted" ];
    }
    # vim (text editor)
    {
      pkg = vim-full;
      bins = [
        "vim"
        "vi"
      ];
    }
    # findutils (find)
    {
      pkg = findutils;
      bins = [ "find" ];
    }
    # gnugrep (grep)
    {
      pkg = gnugrep;
      bins = [ "grep" ];
    }
    # procps (process utilities)
    {
      pkg = procps;
      bins = [
        "ps"
        "kill"
      ];
    }
    # less (pager)
    {
      pkg = less;
      bins = [ "less" ];
    }
    # kmod (module loading)
    {
      pkg = kmod;
      bins = [
        "modprobe"
        "lsmod"
      ];
    }
  ];

  # Generate binary entries for makeInitrdNG
  binaryEntries = lib.flatten (
    map (
      entry:
      map (bin: {
        source = "${entry.pkg}/bin/${bin}";
        target = "/bin/${bin}";
      }) entry.bins
    ) packageBinaries
  );

  # Build the initrd
  initrd = makeInitrdNG {
    name = "mrescue-initrd";
    compressor = "zstd";
    compressorArgs = [
      "-19"
      "-T0"
    ]; # Maximum compression, all threads

    contents = [
      # Init script
      {
        source = init;
        target = "/init";
      }
      # Kernel modules
      {
        source = "${linuxPackages_latest.kernel.modules}/lib/modules";
        target = "/lib/modules";
      }
      # Linux firmware
      {
        source = "${linux-firmware}/lib/firmware";
        target = "/lib/firmware";
      }
    ]
    ++ binaryEntries;
  };

in
# Package both kernel and initrd together
runCommand "mrescue" { } ''
  mkdir -p $out
  ln -s ${linuxPackages_latest.kernel}/bzImage $out/bzImage
  ln -s ${initrd}/initrd $out/initrd
  ln -s ${initrd}/initrd $out/initrd.zst
''
