_default:
    @just --list

# Build qudi-core
build:
    @nix build

# Run qudi-core with GUI
qudi PORT='0':
    @nix run . -- --namespace-port {{PORT}}

# Run qudi-core without GUI
qudi-headless PORT='0':
    @nix run . -- -g --namespace-port {{PORT}}

# Run a Jupyter notebook server for the given directory
notebook DIR='.' PORT='0':
    @nix develop -c jupyter notebook --notebook-dir={{DIR}} --port={{ if PORT == '0' { `nix develop -c python -c 'import socket; s = socket.socket(); s.bind(("localhost", 0)); print(s.getsockname()[1])'` } else { PORT } }}

# Check the flake
check:
    @nix flake check

# Format the project
fmt:
    @nix fmt

# Lint the project
lint:
    @nix run .#lint-project

# Run local CI
ci: check fmt lint build
