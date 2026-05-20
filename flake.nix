{
  description = "Qudi core development flake";

  inputs = {
    utils-nix = {
      url = "git+ssh://git@github.com/SparrowQuantum/utils-nix.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    nixpkgs,
    flake-utils,
    utils-nix,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) lib;

        qtPluginPath = lib.makeSearchPath "lib/qt-6/plugins" [
          pkgs.qt6.qtbase
          pyPkgs.pyside6
        ];
        qtQmlPath = lib.makeSearchPath "lib/qt-6/qml" [
          pkgs.qt6.qtdeclarative
          pyPkgs.pyside6
        ];

        # Python with security overrides from utils-nix
        py = utils-nix.lib.${system}.python;
        pyPkgsOld = utils-nix.lib.${system}.pythonPackages;
        pyPkgs = pyPkgsOld.override {
          overrides = self: super: {
            # Project needs rpyc 5.*.* but nixpkgs is
            rpyc = super.rpyc.overrideAttrs (oldAttrs: rec {
              version = "5.3.1";
              src = pkgs.fetchFromGitHub {
                owner = "tomerfiliba";
                repo = "rpyc";
                tag = version;
                hash = "sha256-2b6ryqDqZPs5VniLhCwA1/c9+3CT+JJrr3VwP3G6tpY=";
              };
            });
          };
        };

        fysom = pyPkgs.buildPythonPackage rec {
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

        pyDeps = with pyPkgs; [
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

        qudiCore = pyPkgs.buildPythonPackage {
          pname = "qudi-core";
          version = pkgs.lib.strings.removeSuffix "\n" (builtins.readFile ./VERSION);
          pyproject = true;
          src = ./.;

          nativeBuildInputs = [
            pkgs.makeWrapper
          ];

          build-system = with pyPkgs; [
            setuptools
            setuptools-scm
            wheel
          ];

          dependencies = pyDeps;

          pythonImportsCheck = ["qudi"];

          postFixup = ''
            wrapProgram "$out/bin/qudi" \
              --prefix QT_PLUGIN_PATH : "${qtPluginPath}" \
              --prefix QML2_IMPORT_PATH : "${qtQmlPath}"
          '';
        };

        qudiLauncher = pkgs.writeScriptBin "qudi-launch" ''
          #!${devEnv}/bin/python

          import os
          import subprocess
          import sys

          subprocess.run(
              ["${devEnv}/bin/python", "-m", "qudi.core.qudikernel", "ensure"],
              check=True,
          )

          os.execv("${qudiCore}/bin/qudi", ["${qudiCore}/bin/qudi", *sys.argv[1:]])
        '';

        devEnv = py.withPackages (ps:
          with ps; [
            qudiCore
          ]);
      in {
        packages = {
          default = qudiCore;
          qudi-core = qudiCore;
        };

        apps = {
          default = {
            type = "app";
            program = "${qudiLauncher}/bin/qudi-launch";
          };
          qudi-core = {
            type = "app";
            program = "${qudiLauncher}/bin/qudi-launch";
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [
            utils-nix.packages.${system}.fmt
            utils-nix.packages.${system}.ruff
            utils-nix.packages.${system}.alejandra
            utils-nix.packages.${system}.deadnix
            utils-nix.packages.${system}.just
            pkgs.uv
            pkgs.which
            pkgs.gh
            pkgs.fd
            devEnv
          ];

          shellHook = ''
            ${devEnv}/bin/python -m qudi.core.qudikernel ensure
          '';
        };
      }
    );
}
