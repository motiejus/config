{
  lib,
  stdenv,
  libgit2,
  sqlite,
  fetchgit,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "stagit";
  version = "2.0-unstable";

  src = fetchgit {
    url = "https://git.jakstys.lt/motiejus/stagit.git";
    rev = "3823da1db67032e263ab4fc6052664d21338bbc3";
    hash = "sha256-d9O0vpWxMXEL1AajA3AWfndxqjKJXEuh1KSu37bG3mA=";
  };

  makeFlags = [ "PREFIX=$(out)" ];

  buildInputs = [
    libgit2
    sqlite
  ];

  meta = {
    description = "Git static site generator";
    homepage = "https://git.jakstys.lt/motiejus/stagit";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
})
