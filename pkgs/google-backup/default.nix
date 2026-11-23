{ buildGoModule }:
buildGoModule {
  name = "google-backup";
  src = ./.;
  vendorHash = "sha256-fTqx4ibPGxevvTvb461rvl99zVcDmncsxPxpiGgpW4w=";
  meta.mainProgram = "google-backup";
}
