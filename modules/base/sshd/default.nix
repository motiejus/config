{
  config,
  lib,
  myData,
  ...
}: {
  config = {
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
      };
    };
    programs.mosh.enable = true;
    programs.ssh.knownHosts = myData.systems;
  };
}
