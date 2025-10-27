{ buildGoModule, pkgs }:
let
  gcloud-wrapper = buildGoModule {
    name = "gcloud-wrapper";
    src = ./.;
    vendorHash = null;
  };
in
pkgs.symlinkJoin {
  name = "google-cloud-sdk-wrapped";
  paths = [ pkgs.google-cloud-sdk ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    # Remove the original gcloud symlink
    rm $out/bin/gcloud

    # Create a shell wrapper called gcloud-wrapped that executes the real gcloud
    makeWrapper ${pkgs.google-cloud-sdk}/bin/gcloud $out/bin/gcloud-wrapped

    # Replace gcloud with our caching wrapper
    ln -s ${gcloud-wrapper}/bin/gcloud-wrapper $out/bin/gcloud
  '';
}
