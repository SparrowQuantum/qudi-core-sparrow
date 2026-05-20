_default:
    just --list

develop:
    nix develop

build:
    nix build .#qudi-core

run *args:
    nix run . -- $args

run-headless *args:
    nix run . -- -g $args

check:
    nix flake check

fmt:
    nix develop -c alejandra flake.nix

xpra-start display="100":
    nix develop -c xpra start :{{display}} --daemon=no --exit-with-children --start-child "nix run ."

xpra-stop display="100":
    nix develop -c xpra stop :{{display}}

xpra-list:
    nix develop -c xpra list