{ buildGoModule }:
buildGoModule {
  pname = "lt-shelters";
  version = "1.0.0";
  src = ./.;
  vendorHash = null;
  subPackages = [
    "cmd/fetch-kas"
    "cmd/fetch-priedangos"
  ];
}
