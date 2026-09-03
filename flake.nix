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
            src = pkgs.lib.fileset.toSource {
              root = ./helper;
              fileset = pkgs.lib.fileset.difference ./helper
                (pkgs.lib.fileset.unions [
                  ./helper/tests
                  ./helper/integration_tests
                ]);
            };

            build-system = [ python.pkgs.setuptools ];
            dependencies = with python.pkgs; [
              jupyter-client
              pyzmq
              pillow
            ];

            # buildPythonApplication maps doCheck to its install-check phase.
            # Runtime builds stay independent of the development suites; the
            # checked variant below enables all test hooks for `nix flake check`.
            doCheck = false;
            dontUsePythonImportsCheck = true;
          };
          ejn-registry-worker = python.pkgs.buildPythonApplication {
            pname = "ejn-registry-worker";
            version = "0.1.0";
            pyproject = true;
            src = pkgs.lib.fileset.toSource {
              root = ./registry_worker;
              fileset = pkgs.lib.fileset.difference ./registry_worker
                ./registry_worker/tests;
            };
            build-system = [ python.pkgs.setuptools ];

            doCheck = false;
            dontUsePythonImportsCheck = true;
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

      checks = forAllSystems (pkgs:
        let
          python = pkgs.python3;
          packages = self.packages.${pkgs.stdenv.hostPlatform.system};
          ejn-helper = packages.ejn-helper.overridePythonAttrs (_old: {
            # The helper's architecture tests also inspect repository-level
            # fixtures and Emacs sources, so checks use the full source tree.
            src = ./.;
            postUnpack = ''
              sourceRoot="$sourceRoot/helper"
            '';
            nativeCheckInputs = with python.pkgs; [ ipykernel pillow ];
            doCheck = true;
            checkPhase = ''
              runHook preCheck
              EJN_REQUIRE_PILLOW=1 \
                PYTHONPATH=${python.pkgs.pillow}/${python.sitePackages}:$PWD/.. \
                python -m unittest discover -s tests -p 'test_*.py'
              runHook postCheck
            '';
            dontUsePythonImportsCheck = false;
            pythonImportsCheck = [ "ejn_helper" ];
          });
          ejn-registry-worker =
            packages.ejn-registry-worker.overridePythonAttrs (_old: {
              src = ./registry_worker;
              # buildPythonApplication runs checkPhase after installation, so
              # the unit suite and installed-command smoke test share it.
              doCheck = true;
              checkPhase = ''
                runHook preCheck
                python -m unittest discover -s tests -p 'test_*.py'
                response=$(printf '%s\n' '{}' | "$out/bin/ejn-registry-worker")
                RESPONSE="$response" python -c 'import json, os; value = json.loads(os.environ["RESPONSE"]); assert value == {"v": 1, "ok": False, "error": {"code": "invalid-request", "message": "registry request has an invalid version"}}'
                runHook postCheck
              '';
              dontUsePythonImportsCheck = false;
              pythonImportsCheck = [ "ejn_registry_worker" ];
            });
        in
        {
          inherit ejn-helper ejn-registry-worker;
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
