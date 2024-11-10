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

test:
    zig build test --summary all -freference-trace

fmt:
    zig fmt src build.zig build.zig.zon
    typos -w

watch cmd="check":
    git ls-files | entr -c just run-clear {{cmd}}

run-clear cmd:
    @clear
    zig build {{cmd}}

