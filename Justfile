set windows-shell := ["powershell"]
set shell := ["bash", "-cu"]

alias c  := check
alias ck := check
alias f  := fmt
alias t  := test

_default:
    @just --list -u

check:
    zig build check -freference-trace

build:
    zig build --summary all -freference-trace --femit-docs

test:
    zig build test --summary all -freference-trace

docs:
    zig build docs --summary new
    npx http-server -p 3000 zig-out/docs

fmt:
    zig fmt src build.zig build.zig.zon
    typos -w

clean:
    rm -rf zig-out .zig-cache

watch cmd="check":
    git ls-files | entr -c just run-clear {{cmd}}

run-clear cmd:
    @clear
    zig build {{cmd}}

