_: {
  config = {
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
      };
    };
    programs.mosh.enable = true;
    programs.ssh.extraConfig = ''
      Host git.jakstys.lt
        HostName fwminex.jakst.vpn
    '';
  };
}
