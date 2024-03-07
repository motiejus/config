{
  fetchFromGitLab,
  fetchFromGitHub,
  #buildArmTrustedFirmware,
  buildUBoot,
}: let
  rkbin = fetchFromGitHub {
    owner = "rockchip-linux";
    repo = "rkbin";
    rev = "a2a0b89b6c8c612dca5ed9ed8a68db8a07f68bc0";
    hash = "sha256-U/jeUsV7bhqMw3BljmO6SI07NCDAd/+sEp3dZnyXeeA=";
  };
  #tfa =
  #  (buildArmTrustedFirmware rec {
  #    extraMakeFlags = ["bl31"];
  #    platform = "rk3588";
  #    extraMeta.platforms = ["aarch64-linux"];
  #    filesToInstall = ["build/${platform}/release/bl31/bl31.elf"];
  #  })
  #  .overrideAttrs (_: {
  #    src = fetchFromGitLab {
  #      domain = "gitlab.collabora.com";
  #      owner = "hardware-enablement";
  #      repo = "rockchip-3588/trusted-firmware-a";
  #      rev = "002d8e85ce5f4f06ebc2c2c52b4923a514bfa701";
  #      hash = "sha256-1XOG7ILIgWa3uXUmAh9WTfSGLD/76OsmWrUhIxm/zTg=";
  #    };
  #  });
in
  buildUBoot rec {
    version = "v2024.04-rc3-52-g773cb2bca7";
    src = fetchFromGitLab {
      domain = "source.denx.de";
      owner = "u-boot";
      repo = "u-boot";
      rev = "773cb2bca7743406e34ab4f441fc0a8a0d200a19";
      hash = "sha256-MOlqc9KvQJcjpWUdnCf2n4KA0a806Tzsu72taUQjmcs=";
    };

    defconfig = "orangepi-5-plus-rk3588_defconfig";

    patches = [];

    ROCKCHIP_TPL = "${rkbin}/bin/rk35/rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.16.bin";
    BL31 = "${rkbin}/bin/rk35/rk3588_bl31_v1.45.elf";

    # FIXME: seems to not like nixpkgs dtc for some reason
    extraMakeFlags = ["DTC=./scripts/dtc/dtc"];

    filesToInstall = [".config" "u-boot.itb" "idbloader.img" "u-boot-rockchip.bin" "u-boot-rockchip-spi.bin"];

    extraMeta.platforms = ["aarch64-linux"];
  }
