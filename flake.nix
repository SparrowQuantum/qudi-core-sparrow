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

        # Python with security overrides from utils-nix
        py = utils-nix.lib.${system}.python;
        pyPkgsOld = utils-nix.lib.${system}.pythonPackages;
        pyPkgs = pyPkgsOld.override {
          overrides = _: super: {
            # Project needs rpyc 5.*.* but nixpkgs is
            rpyc = super.rpyc.overrideAttrs (_: rec {
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

          build-system = with pyPkgs; [
            setuptools
            setuptools-scm
            wheel
          ];

          dependencies = pyDeps;

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

        pythonAudit = utils-nix.lib.${system}.mkPythonAudit [];

        fmtPackage = pkgs.writeShellScriptBin "fmt" ''
          ${pkgs.alejandra}/bin/alejandra . --quiet
        '';
      in {
        packages = {
          default = qudiCore;
        };

        apps = {
          default = {
            type = "app";
            program = "${qudiLauncher}/bin/qudi-launch";
            meta = {
              description = "Launch Qudi-core";
            };
          };
          python-audit = {
            type = "app";
            program = "${pythonAudit}/bin/python-audit";
            meta = {
              description = "Audit Python dependencies for security vulnerabilities";
            };
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [
            utils-nix.packages.${system}.ruff
            utils-nix.packages.${system}.alejandra
            utils-nix.packages.${system}.deadnix
            utils-nix.packages.${system}.just
            pkgs.uv
            pkgs.which
            pkgs.gh
            pkgs.fd
            devEnv
            qudiLauncher
          ];

          shellHook = ''
            ${utils-nix.lib.${system}.mkInstallGitHooks {
              pre-commit = [
                utils-nix.packages.${system}.git-hook-nix-fmt-check
              ];
              commit-msg = [
                utils-nix.packages.${system}.git-hook-conventional-commit
              ];
            }}
          '';
        };

        formatter = fmtPackage;
      }
    );
}
