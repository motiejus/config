# thanks k900
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.mj.plasma;

  setValue =
    v:
    let
      setValueArgs = ty: vs: "--type ${ty} ${lib.escapeShellArg vs}";
    in
    if builtins.isBool v then
      setValueArgs "bool" (if v then "true" else "false")
    else
      setValueArgs "str" (builtins.toString v);

  pathToArgs =
    path:
    let
      groupArg = item: "--group ${lib.escapeShellArg item}";
      groupArgs = builtins.map groupArg path;
    in
    groupArgs;

  entryToArgs =
    { path, value }:
    let
      file = builtins.head path;
      subpath = builtins.tail path;
      groups = lib.lists.init subpath;
      name = lib.lists.last subpath;

      fileArg = "--file ${lib.escapeShellArg file}";
      pathArgs = pathToArgs groups;
      keyArg = "--key ${lib.escapeShellArg name}";
      valueArg = setValue value;
      allArgs = pathArgs ++ [
        fileArg
        keyArg
        valueArg
      ];
    in
    lib.strings.concatStringsSep " " allArgs;

  flattenAttrs =
    attrs: pathSoFar:
    lib.lists.flatten (
      lib.attrsets.mapAttrsToList (
        name: value:
        if builtins.isAttrs value then
          flattenAttrs value (pathSoFar ++ [ name ])
        else
          {
            path = pathSoFar ++ [ name ];
            inherit value;
          }
      ) attrs
    );

  configToArgs = attrs: builtins.map entryToArgs (flattenAttrs attrs [ ]);

  configToScript =
    attrs:
    let
      args = configToArgs attrs;
      argToCommand = arg: "${pkgs.kdePackages.kconfig}/bin/kwriteconfig6 ${arg}";
      commands = builtins.map argToCommand args;
    in
    lib.strings.concatStringsSep "\n" commands;

  writeConfig = attrs: pkgs.writeScript "kconfig-setup" (configToScript attrs);
in
{
  options.mj.plasma = {
    kconfig = lib.mkOption {
      type = lib.types.attrs;
      default = { };
    };
  };

  config = lib.mkIf (cfg.kconfig != { }) {
    home.activation.kconfig-setup = "$DRY_RUN_CMD ${writeConfig cfg.kconfig}";
  };
}
