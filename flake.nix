{
  description = "Emacs Jupyter Notebook helper transport";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = function:
        nixpkgs.lib.genAttrs systems (system: function nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs:
        let
          python = pkgs.python3;
          ejn-helper = python.pkgs.buildPythonApplication {
            pname = "ejn-helper";
            version = "0.1.0";
            pyproject = true;
            # Keep the repository root available during checks: helper tests
            # import helper.tests and share fixtures with the Emacs tests.
            src = ./.;
            postUnpack = ''
              sourceRoot="$sourceRoot/helper"
            '';

            build-system = [ python.pkgs.setuptools ];
            dependencies = with python.pkgs; [
              jupyter-client
              pyzmq
              pillow
            ];

            # The Python builder runs this suite as an install check, where
            # runtime dependencies are not guaranteed on the check-time
            # module path.  Keep the real decoder boundary exercised there.
            nativeCheckInputs = with python.pkgs; [ ipykernel pillow ];
            doCheck = true;
            checkPhase = ''
              runHook preCheck
              EJN_REQUIRE_PILLOW=1 \
                PYTHONPATH=${python.pkgs.pillow}/${python.sitePackages}:$PWD/.. \
                python -m unittest discover -s tests -p 'test_*.py'
              runHook postCheck
            '';
            pythonImportsCheck = [ "ejn_helper" ];
          };
        in
        {
          inherit ejn-helper;
          default = ejn-helper;
        });

      apps = forAllSystems (pkgs: {
        ejn-helper = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.ejn-helper}/bin/ejn-helper";
          meta.description = "Run the EJN local Jupyter transport helper";
        };
        default = self.apps.${pkgs.stdenv.hostPlatform.system}.ejn-helper;
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            (pkgs.python3.withPackages (python: with python; [
              ipykernel
              jupyter-client
              pyzmq
              pillow
            ]))
          ];
        };
      });
    };
}
