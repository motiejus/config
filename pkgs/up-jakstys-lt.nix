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
    rev = "8cb7e6357fae1e7ddf86f9cc69e8960d605c6fcbb09490aab8b32c509c16d462";
    # The repo is in sha256 object format; see pkgs/stagit-ng.nix.
    preFetch = "export GIT_DEFAULT_HASH=sha256";
    hash = "sha256-z0T1ACVsPsgk7Zh3dzLsi39xBhO48nbA5F/P6G6rBTc=";
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
