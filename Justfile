alias c  := check
alias ck := check
alias f  := fmt
alias t  := test

_default:
    @just --list -u

check:
    zig build check -freference-trace

test:
    zig build test --summary all

fmt:
    zig fmt src/**/*.zig build.zig build.zig.zon
    typos -w
