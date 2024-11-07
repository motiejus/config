{ config, ... }:
{
  config = {
    documentation = {
      dev.enable = true;
      doc.enable = true;
      info.enable = true;
      man = {
        enable = true;
        man-db.enable = false;
        mandoc.enable = true;
      };
    };

  };

}
