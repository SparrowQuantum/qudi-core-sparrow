_default:
    just --list

# Build qudi-core
build:
    nix build

# Run qudi-core with GUI
qudi:
    nix run

# Run qudi-core without GUI
qudi-headless:
    nix run . -- -g 

# Run a Jupyter notebook server for the given directory
notebook DIR='.':
    nix develop -c jupyter notebook --notebook-dir={{DIR}}

# Check the flake
check:
    nix flake check

# Format the project
fmt:
    nix develop -c alejandra flake.nix

# Run Python security audit
audit:
    nix run .#python-audit