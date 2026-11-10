# om3.nix - OpenSVC v3 built from the pinned source (flake input om3-src).
#
# No om3/opensvc package exists in nixpkgs. The vendorHash is learned from the
# builder: `bash lab/builder/check.sh pkg om3` prints "got: sha256-..." when it
# is stale. Bump the tag in flake.nix, set vendorHash to lib.fakeHash, build,
# and paste the printed hash.
{ lib, buildGoModule, src, version }:

buildGoModule {
  pname = "om3";
  inherit version src;

  vendorHash = "sha256-+mbzKb2KjDB6MXF4C1x8KZKuX9nTgV7hil1dJdc5b1o=";

  # om is the node/cluster command and the daemon (`om daemon run`); ox is the
  # remote client and is not shipped.
  subPackages = [ "cmd/om" ];

  # `om version` reads util/version/text/VERSION (embedded at build); a Nix
  # build has no git history for the vcs.revision fallback.
  preBuild = ''
    echo "v${version}" > util/version/text/VERSION
  '';

  # The unit tests of om3 need a running daemon, root and a network.
  doCheck = false;

  meta = {
    description = "OpenSVC v3: cluster membership, health and local service management";
    homepage = "https://github.com/opensvc/om3";
    mainProgram = "om";
  };
}
