{
  lib,
  pkgs,
}:

let
  # Simple init script
  init = pkgs.writeScript "init" ''
    #!${pkgs.bash}/bin/bash
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
  packages = with pkgs; [
    vim
    bash
    less
    kmod
    parted
    procps
    gnugrep
    findutils
    e2fsprogs
    dosfstools
    btrfs-progs
    util-linux
    uutils-coreutils-noprefix
  ];

  # Generate binary entries for makeInitrdNG by auto-discovering all binaries
  binaryEntries =
    let
      # Collect all entries with package info
      allEntriesWithPkg = lib.flatten (
        map (
          pkg:
          let
            binDir = "${pkg}/bin";
            # Get all files in the bin directory
            binFiles = if builtins.pathExists binDir then builtins.attrNames (builtins.readDir binDir) else [ ];
            pkgName = pkg.name or (builtins.baseNameOf (builtins.toString pkg));
          in
          map (bin: {
            source = "${binDir}/${bin}";
            target = "/bin/${bin}";
            package = pkgName;
            binary = bin;
          }) binFiles
        ) packages
      );

      # Build map of binary -> list of packages providing it
      binaryMap = lib.foldl' (
        acc: entry:
        let
          existing = acc.${entry.binary} or [ ];
        in
        acc // { ${entry.binary} = existing ++ [ entry.package ]; }
      ) { } allEntriesWithPkg;

      # Deduplicate by target path, keeping first occurrence and warning about duplicates
      deduped = lib.foldl' (
        acc: entry:
        let
          alreadyExists = builtins.any (e: e.target == entry.target) acc;
          providers = binaryMap.${entry.binary};
          hasDuplicates = builtins.length providers > 1;
        in
        if alreadyExists then
          acc
        else if hasDuplicates then
          builtins.trace
            "Warning: binary '${entry.binary}' provided by multiple packages: ${builtins.concatStringsSep ", " providers}. Chose: ${entry.package}"
            (acc ++ [ entry ])
        else
          acc ++ [ entry ]
      ) [ ] allEntriesWithPkg;
    in
    deduped;

  initrd = pkgs.makeInitrdNG {
    name = "mrescue-initrd";
    compressor = "zstd";
    compressorArgs = [
      #"-19"
      "-12"
      "-T0"
    ];

    contents = [
      {
        source = init;
        target = "/init";
      }
      {
        source = "${pkgs.linuxPackages_latest.kernel.modules}/lib/modules";
        target = "/lib/modules";
      }
    ]
    ++ binaryEntries; # makeInitrdNG will auto-resolve dependencies for these
  };

in
# Package both kernel and initrd together
pkgs.runCommand "mrescue" { } ''
  mkdir -p $out
  ln -s ${pkgs.linuxPackages_latest.kernel}/bzImage $out/bzImage
  ln -s ${initrd}/initrd $out/initrd
  ln -s ${initrd}/initrd $out/initrd.zst
''
