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
          ejn-registry-worker = python.pkgs.buildPythonApplication {
            pname = "ejn-registry-worker";
            version = "0.1.0";
            pyproject = true;
            src = ./registry_worker;
            build-system = [ python.pkgs.setuptools ];

            doCheck = true;
            checkPhase = ''
              runHook preCheck
              python -m unittest discover -s tests -p 'test_*.py'
              runHook postCheck
            '';
            doInstallCheck = true;
            installCheckPhase = ''
              runHook preInstallCheck
              response=$(printf '%s\n' '{}' | "$out/bin/ejn-registry-worker")
              RESPONSE="$response" python -c 'import json, os; value = json.loads(os.environ["RESPONSE"]); assert value == {"v": 1, "ok": False, "error": {"code": "invalid-request", "message": "registry request has an invalid version"}}'
              runHook postInstallCheck
            '';
            pythonImportsCheck = [ "ejn_registry_worker" ];
          };
          ejn-runtime = pkgs.symlinkJoin {
            name = "emacs-jupyter-notebook-runtime";
            paths = [ ejn-helper ejn-registry-worker ];
            postBuild = ''
              test -x "$out/bin/ejn-helper"
              test -x "$out/bin/ejn-registry-worker"
            '';
          };
        in
        {
          inherit ejn-helper ejn-registry-worker ejn-runtime;
          default = ejn-runtime;
        });

      apps = forAllSystems (pkgs: {
        ejn-helper = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.ejn-helper}/bin/ejn-helper";
          meta.description = "Run the EJN local Jupyter transport helper";
        };
        ejn-registry-worker = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.ejn-registry-worker}/bin/ejn-registry-worker";
          meta.description = "Run one transactional EJN registry operation";
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
