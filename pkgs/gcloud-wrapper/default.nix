{ buildGoModule }:
buildGoModule {
  name = "gcloud-wrapper";
  src = ./.;
  vendorHash = null;
}
