_: {
  config = {
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
      };
    };
    programs.mosh.enable = true;
  };
}
