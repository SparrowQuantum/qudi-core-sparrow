{
  description = "Qudi core development flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    nixpkgs,
    flake-utils,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) lib;

        pythonOverrides = _: super: {
          # Project needs rpyc 5.*.* but nixpkgs is currently on >6.0.0
          rpyc = super.rpyc.overridePythonAttrs (_: rec {
            version = "5.3.1";
            src = pkgs.fetchFromGitHub {
              owner = "tomerfiliba";
              repo = "rpyc";
              tag = version;
              hash = "sha256-2b6ryqDqZPs5VniLhCwA1/c9+3CT+JJrr3VwP3G6tpY=";
            };
          });

          # Fysom does not exist in nixpkgs, so we build it ourselves
          fysom = super.buildPythonPackage rec {
            pname = "fysom";
            version = "2.1.6";
            format = "setuptools";
            src = pkgs.fetchPypi {
              inherit pname version;
              sha256 = "sha256-42F7efGSIMcrHH5p1NbCo2qAzb6A9N973rq1q0yJO/U=";
            };
            doCheck = false;
            meta = {
              description = "Finite State Machine for Python";
              homepage = "https://github.com/mriehl/fysom";
              license = lib.licenses.mit;
            };
          };
        };

        mkQudiPackage = {
          pkgs,
          python,
        }:
          python.pkgs.buildPythonPackage {
            pname = "qudi-core";
            version = lib.strings.removeSuffix "\n" (builtins.readFile ./VERSION);
            pyproject = true;
            src = ./.;

            build-system = with python.pkgs; [
              setuptools
              setuptools-scm
              wheel
            ];

            dependencies = with python.pkgs; [
              cycler
              entrypoints
              fysom
              gitpython
              jupyter
              jupytext
              lmfit
              matplotlib
              numpy
              pyqtgraph
              pyside6
              rpyc
              ruamel-yaml
              scipy
              jsonschema
              qtconsole
            ];

            nativeBuildInputs = [
              pkgs.qt6.wrapQtAppsHook
            ];
            buildInputs = [
              pkgs.qt6.qtsvg # SVG QIcon support. Propagates qtbase
            ];

            # Wrap app to set environment variables for Qt plugins
            postFixup = ''
              wrapQtApp "$out/bin/qudi"
            '';

            pythonImportsCheck = ["qudi"];

            meta = {
              description = "A framework for modular measurement applications";
              homepage = "https://github.com/SparrowQuantum/qudi-core-sparrow";
              license = lib.licenses.lgpl3;
            };
          };

        python = pkgs.python313.override {packageOverrides = pythonOverrides;};
        qudiCore = mkQudiPackage {inherit pkgs python;};

        devEnv = python.withPackages (_: [qudiCore]);

        fmtPackage = pkgs.writeShellScriptBin "fmt" ''
          ${pkgs.alejandra}/bin/alejandra . --quiet
        '';

        lintPackage = pkgs.writeShellScriptBin "lint-project" ''
          ${pkgs.deadnix}/bin/deadnix .
        '';
      in {
        packages = {
          default = qudiCore;
          qudi-core = qudiCore;
        };

        lib = {
          pythonOverrides = pythonOverrides;
          mkQudiPackage = mkQudiPackage;
        };

        apps = {
          default = {
            type = "app";
            program = "${qudiCore}/bin/qudi";
            meta = {
              description = "Launch Qudi-core";
            };
          };
          lint-project = {
            type = "app";
            program = "${lintPackage}/bin/lint-project";
            meta = {
              description = "Run deadnix on the project";
            };
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.ruff
            pkgs.alejandra
            pkgs.deadnix
            pkgs.just
            pkgs.uv
            pkgs.which
            pkgs.gh
            pkgs.fd
            devEnv
          ];
        };

        formatter = fmtPackage;
      }
    );
}
