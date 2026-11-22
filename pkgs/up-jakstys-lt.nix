{
  lib,
  buildGoModule,
  fetchgit,
}:
buildGoModule {
  pname = "up";
  version = "0-unstable-2026-11-23";

  src = fetchgit {
    url = "https://git.jakstys.lt/up.jakstys.lt.git";
    rev = "dc418885a713b99c79932550835235a24f5f8a793dbdf19413b7cca45b94b7ac";
    # The repo is in sha256 object format; see pkgs/stagit-ng.nix.
    preFetch = "export GIT_DEFAULT_HASH=sha256";
    hash = "sha256-xdDxY83Qrl6TDCrMUN2/vnrEaT9H2HDXS7UY1ca6jMg=";
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

  meta = {
    description = "tus upload service behind up.jakstys.lt";
    mainProgram = "up";
    license = lib.licenses.mit;
  };
}
