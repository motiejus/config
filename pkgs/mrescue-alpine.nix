{
  pkgs,
  stdenv,
  fetchurl,
}:

stdenv.mkDerivation rec {
  pname = "mrescue-alpine";
  version = "3.23.2";

  src = fetchurl {
    url = "https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/x86_64/alpine-netboot-${version}-x86_64.tar.gz";
    hash = "sha256-nFfzrPH1KI2R3OXBOluV7wB/hY63ImxWp/tyzBahpK0=";
  };

  nativeBuildInputs = with pkgs; [
    gzip
    cpio
    squashfsTools
    findutils
    zstd
  ];

  sourceRoot = ".";

  unpackPhase = ''
    runHook preUnpack
    mkdir alpine-boot
    tar -xzf $src -C alpine-boot --strip-components=1
    runHook postUnpack
  '';

  buildPhase = ''
    runHook preBuild

    mkdir -p work/initramfs-extracted
    cd work

    gzip -dc < ../alpine-boot/initramfs-virt | \
      cpio -idm --quiet -D initramfs-extracted

    unsquashfs -f -d modloop-extracted ../alpine-boot/modloop-virt >/dev/null

    mkdir -p initramfs-extracted/lib/modules
    cp -r modloop-extracted/modules/* initramfs-extracted/lib/modules/

    # Initialize apk database
    mkdir -p initramfs-extracted/lib/apk/db
    mkdir -p initramfs-extracted/etc/apk
    touch initramfs-extracted/lib/apk/db/installed
    touch initramfs-extracted/etc/apk/world
    echo "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main" > initramfs-extracted/etc/apk/repositories
    echo "https://dl-cdn.alpinelinux.org/alpine/latest-stable/community" >> initramfs-extracted/etc/apk/repositories

    cd initramfs-extracted
    find * .[^.*] -print0 | sort -z | \
      cpio --quiet -o -H newc -R +0:+0 --reproducible --null | \
      zstd -19 -T8 > ../initramfs-combined.zst

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    install -Dm644 ../../alpine-boot/vmlinuz-virt $out/kernel
    install -Dm644 ../initramfs-combined.zst $out/initrd

    runHook postInstall
  '';
}
