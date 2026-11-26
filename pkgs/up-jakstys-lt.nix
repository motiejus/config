{
  lib,
  buildGoModule,
  fetchgit,
  runCommand,
  compressDrvWebEtag,
}:
buildGoModule (finalAttrs: {
  pname = "up";
  version = "0-unstable-2026-11-26";

  src = fetchgit {
    url = "https://git.jakstys.lt/up.jakstys.lt.git";
    rev = "fb79bd3894a90329cb3bbd4b5f10bf41720773418eef0bbb71870f5b777c1087";
    # The repo is in sha256 object format; see pkgs/stagit-ng.nix.
    preFetch = "export GIT_DEFAULT_HASH=sha256";
    hash = "sha256-2Xjx886gdeHFR89XA+oliczDM7fhaPX+gFkxGFno3L0=";
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
