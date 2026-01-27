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

    # Drop to rescue shell
    exec /bin/bash
  '';

  # Packages to include (all binaries from each package will be included)
  packages = [
    uutils-coreutils-noprefix
    bash
    util-linux
    e2fsprogs
    dosfstools
    parted
    vim-full
    findutils
    gnugrep
    procps
    less
    kmod
  ];

  # Generate binary entries for makeInitrdNG by auto-discovering all binaries
  binaryEntries =
    let
      allEntries = lib.flatten (
        map (
          pkg:
          let
            binDir = "${pkg}/bin";
            # Get all files in the bin directory
            binFiles = if builtins.pathExists binDir then builtins.attrNames (builtins.readDir binDir) else [ ];
          in
          map (bin: {
            source = "${binDir}/${bin}";
            target = "/bin/${bin}";
          }) binFiles
        ) packages
      );
      # Deduplicate by target path, keeping first occurrence
      deduped = lib.foldl' (
        acc: entry: if builtins.any (e: e.target == entry.target) acc then acc else acc ++ [ entry ]
      ) [ ] allEntries;
    in
    deduped;

  initrd = makeInitrdNG {
    name = "mrescue-initrd";
    compressor = "zstd";
    compressorArgs = [
      #"-19"
      "-12"
      "-T0"
    ];

    contents = [
      # Init script
      {
        source = init;
        target = "/init";
      }
      # Kernel modules (not ELF binaries, must be added manually)
      {
        source = "${linuxPackages_latest.kernel.modules}/lib/modules";
        target = "/lib/modules";
      }
    ]
    ++ binaryEntries; # makeInitrdNG will auto-resolve dependencies for these
  };

in
# Package both kernel and initrd together
runCommand "mrescue" { } ''
  mkdir -p $out
  ln -s ${linuxPackages_latest.kernel}/bzImage $out/bzImage
  ln -s ${initrd}/initrd $out/initrd
  ln -s ${initrd}/initrd $out/initrd.zst
''
