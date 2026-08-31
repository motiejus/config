{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.mj.services.lt-maps;
in
{
  options.mj.services.lt-maps = {
    mbFontsDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "config.mj.services.mb-type-fonts.package";
      description = "A font tree to build the site's map labels from; null is upstream's.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default =
        if cfg.mbFontsDir == null then
          pkgs.lt-maps
        else
          (pkgs.lt-maps-set.override { mbFontsDir = "${cfg.mbFontsDir}"; }).compressed;
      description = "The maps.jakstys.lt site, with mbFontsDir applied.";
    };
  };
}
