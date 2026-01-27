{
  lib,
  runCommand,
  symlinkJoin,
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
  glibc,
  gcc-unwrapped,
}:

let
  # Simple init script
  init = writeScript "init" ''
    #!${bash}/bin/bash
    set -e

    # Set up PATH first
    export PATH=/bin
    export HOME=/root
    export TERM=linux

    # Create mount points
    mkdir -p /proc /sys /dev /run /tmp

    # Mount essential filesystems
    mount -t proc proc /proc
    mount -t sysfs sys /sys
    mount -t devtmpfs dev /dev

    # Load essential kernel modules for hardware support
    echo "Loading kernel modules..."
    modprobe -a \
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
    echo "Kernel modules included."
    echo "Type 'exit' or Ctrl+D to reboot"
    echo ""

    # Drop to rescue shell
    exec /bin/bash
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

  # Merge glibc and gcc libraries into one directory
  mergedLibs = symlinkJoin {
    name = "merged-libs";
    paths = [
      glibc
      gcc-unwrapped.lib
    ];
  };

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
      #"-19"
      "-9"
      "-T0"
    ]; # Maximum compression, all threads

    contents = [
      # Init script
      {
        source = init;
        target = "/init";
      }
      # Merged C libraries (glibc + gcc)
      {
        source = "${mergedLibs}/lib";
        target = "/lib";
      }
      # Dynamic linker (also at /lib64 for compatibility)
      {
        source = "${mergedLibs}/lib/ld-linux-x86-64.so.2";
        target = "/lib64/ld-linux-x86-64.so.2";
      }
      # Kernel modules
      {
        source = "${linuxPackages_latest.kernel.modules}/lib/modules";
        target = "/lib/modules";
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
