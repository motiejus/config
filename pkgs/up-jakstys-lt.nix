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
    rev = "d1bf18c5a742d9597d4dce7dfbabc1ac0c7dfa3209ebd12bacac3de2cd359400";
    # The repo is in sha256 object format; see pkgs/stagit-ng.nix.
    preFetch = "export GIT_DEFAULT_HASH=sha256";
    hash = "sha256-L0hYDUj9IBAM84uj2X3vVmvrC3vXrHQKlJWJ4s3QWxI=";
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
