{
  fetchFromGitLab,
  fetchFromGitHub,
  buildArmTrustedFirmware,
  buildUBoot,
}: let
  rkbin = fetchFromGitHub {
    owner = "rockchip-linux";
    repo = "rkbin";
    rev = "b4558da0860ca48bf1a571dd33ccba580b9abe23";
    hash = "sha256-KUZQaQ+IZ0OynawlYGW99QGAOmOrGt2CZidI3NTxFw8=";
  };

  tfa =
    (buildArmTrustedFirmware rec {
      extraMakeFlags = ["bl31"];
      platform = "rk3588";
      extraMeta.platforms = ["aarch64-linux"];
      filesToInstall = ["build/${platform}/release/bl31/bl31.elf"];
    })
    .overrideAttrs (_: {
      src = fetchFromGitLab {
        domain = "gitlab.collabora.com";
        owner = "hardware-enablement";
        repo = "rockchip-3588/trusted-firmware-a";
        rev = "002d8e85ce5f4f06ebc2c2c52b4923a514bfa701";
        hash = "sha256-1XOG7ILIgWa3uXUmAh9WTfSGLD/76OsmWrUhIxm/zTg=";
      };
    });
in
  buildUBoot rec {
    version = "2024.01";

    src = fetchFromGitLab {
      domain = "source.denx.de";
      owner = "u-boot";
      repo = "u-boot";
      rev = "v${version}";
      hash = "sha256-0Da7Czy9cpQ+D5EICc3/QSZhAdCBsmeMvBgykYhAQFw=";
    };

    defconfig = "orangepi-5-plus-rk3588_defconfig";
    extraConfig = ''CONFIG_ROCKCHIP_SPI_IMAGE=y'';

    patches = [];

    ROCKCHIP_TPL = "${rkbin}/bin/rk35/rk3588_ddr_lp4_2112MHz_lp5_2736MHz_v1.12.bin";
    BL31 = "${tfa}/bl31.elf";

    # FIXME: seems to not like nixpkgs dtc for some reason
    extraMakeFlags = ["DTC=./scripts/dtc/dtc"];

    filesToInstall = [".config" "u-boot.itb" "idbloader.img" "u-boot-rockchip.bin" "u-boot-rockchip-spi.bin"];

    extraMeta.platforms = ["aarch64-linux"];
  }
