{
  lib,
  stdenv,
  zig,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "g602";
  version = "0.1.0";

  src = lib.cleanSource ../.;

  nativeBuildInputs = [zig.hook];

  zigBuildFlags = ["-Doptimize=ReleaseSafe"];

  meta = {
    description = "Userspace input interposer for the Logitech G602";
    mainProgram = "g602";
    platforms = lib.platforms.linux;
  };
})
