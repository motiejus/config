{
  buildGoModule,
  compressDrvWeb,
  fetchgit,
  runCommand,
}:

let
  src = fetchgit {
    url = "https://git.jakstys.lt/rita.jakstys.lt.git";
    rev = "8b474837b83f14da5848b8faf32535e318b7a42c";
    hash = "sha256-z6YRwvM2QxYGflbd03jdn7Fqs2mJqcwdB0/i9EFT41I=";
  };
  compressedAdminAssets = compressDrvWeb (runCommand "rita-jakst-publisher-admin-assets" { } ''
    mkdir -p $out/{static,assets}
    cp ${src}/static/{admin.css,admin.js} $out/static/
    cp ${src}/assets/prose.css $out/assets/
  '') { };
  adminAssets = runCommand "rita-jakst-publisher-admin-assets-etag" { } ''
    cp -rL --no-preserve=mode ${compressedAdminAssets} $out
    find $out -type f ! -name '*.etag' | while read -r f; do
      h=$(sha256sum "$f")
      printf '"%s"' "''${h:0:32}" > "$f.etag"
    done
  '';
in
buildGoModule (finalAttrs: {
  pname = "rita-jakst-publisher";
  version = "0-unstable";
  inherit src;
  vendorHash = "sha256-v5NTABRYrLKNIpYkYy8SDOsx3o5WbHOZ8mRy1fa4/ko=";

  postInstall = ''
    install -Dm644 ${src}/deploy/Caddyfile.snippet \
      $out/share/rita-jakst-publisher/Caddyfile.snippet
  '';

  meta.mainProgram = "rita.jakstys.lt";

  passthru = {
    inherit adminAssets;
    caddyfile = "${finalAttrs.finalPackage}/share/rita-jakst-publisher/Caddyfile.snippet";
  };
})
