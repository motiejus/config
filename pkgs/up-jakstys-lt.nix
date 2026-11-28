{
  lib,
  buildGoModule,
  fetchgit,
  runCommand,
  compressDrvWebEtag,
}:
buildGoModule (finalAttrs: {
  pname = "up";
  version = "0-unstable-2026-11-28";

  src = fetchgit {
    url = "https://git.jakstys.lt/up.jakstys.lt.git";
    rev = "2a8539b4ee3facd71e6b2bd46e9ecefe05f028081d19988884f9b44afadd60eb";
    # The repo is in sha256 object format; see pkgs/stagit-ng.nix.
    preFetch = "export GIT_DEFAULT_HASH=sha256";
    hash = "sha256-HGRjFwL2StYVV/pbvnokNctCEeaRDTIYxgU0FXzypxE=";
  };

  # go-sqlite3 compiles its bundled SQLite amalgamation; cgo is on by default.
  vendorHash = "sha256-9pqfZpPjGG2AebrlqT+AtCoKivopYxxXgsBKfXXXB34=";

  ldflags = [
    "-s"
    "-w"
  ];

  # The binary is named after the module path's last element.
  postInstall = ''
    mv $out/bin/up.jakstys.lt $out/bin/up
  '';

  # Caddy serves ui/ and routes both sites by the repo's deploy/ snippets;
  # the binary only answers /api/ and /files/.
  passthru = {
    www = compressDrvWebEtag (runCommand "up-www" { } ''
      cp -r ${finalAttrs.src}/ui $out
    '') { };
    caddySnippet = "${finalAttrs.src}/deploy/Caddyfile.snippet";
    caddyAdminSnippet = "${finalAttrs.src}/deploy/Caddyfile.admin.snippet";
  };

  meta = {
    description = "tus upload service behind up.jakstys.lt";
    mainProgram = "up";
    license = lib.licenses.mit;
  };
})
