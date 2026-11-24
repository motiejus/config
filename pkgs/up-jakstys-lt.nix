{
  lib,
  buildGoModule,
  fetchgit,
  runCommand,
  compressDrvWebEtag,
}:
buildGoModule (finalAttrs: {
  pname = "up";
  version = "0-unstable-2026-11-25";

  src = fetchgit {
    url = "https://git.jakstys.lt/up.jakstys.lt.git";
    rev = "cf1e257d21e2c427d3e147496e3fa87f31918563ded1b8170ca45181149d7be0";
    # The repo is in sha256 object format; see pkgs/stagit-ng.nix.
    preFetch = "export GIT_DEFAULT_HASH=sha256";
    hash = "sha256-nx3V5buhz3xqRrBvJNYmYKE9gOUfdxsGFMp4d+0AdkQ=";
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
