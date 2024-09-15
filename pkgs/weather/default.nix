{ buildGoModule }:
buildGoModule {
  name = "weather";
  src = ./.;
  vendorHash = null;
}
