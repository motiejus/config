{
  lib,
  buildGoModule,
  fetchgit,
  runCommand,
  compressDrvWebEtag,
}:
buildGoModule (finalAttrs: {
  pname = "up";
  version = "0-unstable-2026-11-24";

  src = fetchgit {
    url = "https://git.jakstys.lt/up.jakstys.lt.git";
    rev = "c46d60491d2e4d03495318e74ba45240e602a5f5b82c3f61973879ed84776ad3";
    # The repo is in sha256 object format; see pkgs/stagit-ng.nix.
    preFetch = "export GIT_DEFAULT_HASH=sha256";
    hash = "sha256-8dN5KkG3t063tDwlD/B+M/u9+BiYj6pAaO2eQkB/ZVc=";
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
