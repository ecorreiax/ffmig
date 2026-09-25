{
  description = "ffmig - database-agnostic migration CLI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = pkgs.zig;
        # Read from build.zig.zon, which `ffmig --version` prints too.
        version = builtins.head (builtins.match ''.*[.]version = "([^"]+)".*'' (builtins.readFile ./build.zig.zon));
      in
      {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "ffmig";
          inherit version;
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [ ./build.zig ./build.zig.zon ./src ];
          };
          nativeBuildInputs = [ zig.hook pkgs.pkg-config ];
          buildInputs = [ pkgs.libpq ];
        };

        apps.default = flake-utils.lib.mkApp {
          drv = self.packages.${system}.default;
        };

        devShells.default = pkgs.mkShell {
          # libpq is linked by ffmig; postgresql runs the integration tests;
          # nodejs builds the docs site.
          packages = [ zig pkgs.zls pkgs.pkg-config pkgs.libpq pkgs.postgresql pkgs.nodejs ];
        };
      });
}
