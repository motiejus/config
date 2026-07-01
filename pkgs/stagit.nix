{
  lib,
  stdenv,
  libgit2,
  sqlite,
  fetchgit,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "stagit";
  version = "2.0";

  src = fetchgit {
    url = "https://git.jakstys.lt/motiejus/stagit.git";
    rev = finalAttrs.version;
    hash = "sha256-ccVl0XkzrrdLI5QJ8+yZz4IojOvXYO3HKpqDsQ0qJZk=";
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
