# ctrl-exec-executor-static.nix - the ctrl-exec executor (one C file, libcap) as
# a static binary, for an OS that has no Nix store and no glibc: the Alpine
# package ctrl-exec-agent (docs/BUILDER.md "Local packages"). Built with
# pkgsStatic (musl, libcap's static library); `file` says "statically linked".
# `src` is the ctrl-exec flake input (the same source the NixOS agent is built
# from), so one source gives the dynamic NixOS executor and this one.
{ stdenv, libcap, src }:

stdenv.mkDerivation {
  pname = "ctrl-exec-executor-static";
  version = builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile "${src}/VERSION");
  dontUnpack = true;
  buildInputs = [ libcap ];
  # Same flags as the ctrl-exec Makefile, plus -static: a dynamic link is a
  # build failure here, not a quiet fallback.
  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Wextra -static -o ctrl-exec-executor ${src}/src/ctrl-exec-executor.c -lcap
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 ctrl-exec-executor $out/bin/ctrl-exec-executor
    runHook postInstall
  '';
  meta.description = "ctrl-exec executor, static (musl), for Alpine";
}
