{ buildGoModule }:
buildGoModule {
  name = "google-contacts";
  src = ./.;
  vendorHash = "sha256-fTqx4ibPGxevvTvb461rvl99zVcDmncsxPxpiGgpW4w=";
  meta.mainProgram = "google-contacts";
}
