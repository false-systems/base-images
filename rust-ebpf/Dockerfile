# syntax=docker/dockerfile:1
#
# ghcr.io/false-systems/rust-builder:<RUST_BUILDER_VERSION>-ebpf
#
# rust-builder plus what an aya eBPF build needs on top: the dated nightly
# (with rust-src, for -Z build-std=core against bpfel-unknown-none) and
# bpf-linker. For jalki and selko's Linux sensor.
#
# The base is the rust-builder built in the SAME run: docker-bake.hcl passes
# RUST_BUILDER=rust-builder and binds that name to the rust-builder target, so
# the two tags always share one stable toolchain. The default below is only
# for a standalone `docker build rust-ebpf/`.
ARG RUST_BUILDER=ghcr.io/false-systems/rust-builder:1.97.1
FROM ${RUST_BUILDER}

# The nightly jalki pins in jalki-ebpf/rust-toolchain.toml. Move them together:
# jalki's `rustup toolchain install` is then a no-op in this image.
ARG EBPF_NIGHTLY=nightly-2026-09-25
# bpf-linker 0.10.4's default features (rust-llvm-22) do not link an LLVM:
# at link time it dlopens libLLVM from the sysroot of the rustc that invokes
# it, i.e. from EBPF_NIGHTLY. So "its LLVM" is the nightly's (LLVM 23 for
# nightly-2026-09-25), reached through llvm-sys 22's C-API bindings, which
# this pair shares. A nightly bump can break that, so ci/smoke.sh links a real
# BPF object with this exact pair before any push. 0.11.x needs a system LLVM
# via llvm-config instead; it broke every jalki build the day it was released,
# which is why the version is pinned.
ARG BPF_LINKER_VERSION=0.10.4

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# --no-self-update: rustup must not replace itself mid-build. The chmod (for a
# non-root build user) touches only what this RUN added: a recursive chmod of
# all of $RUSTUP_HOME would copy the stable toolchain into this layer again.
RUN set -eux; \
    rustup toolchain install "$EBPF_NIGHTLY" --profile minimal \
      --component rust-src --no-self-update; \
    rustc +"$EBPF_NIGHTLY" -vV; \
    chmod -R a+w "$RUSTUP_HOME/toolchains/${EBPF_NIGHTLY}-"* "$RUSTUP_HOME/update-hashes"

# Compiled with the stable toolchain (the image default), as jalki does, and
# through cargo-auditable so scanners can read its dependency list. --locked
# uses the crate's own Cargo.lock; crates.io checksums verify every download.
# The registry is dropped afterwards: the cache is 100+ MB and nothing reuses it.
RUN set -eux; \
    cargo auditable install --locked --root /usr/local "bpf-linker@${BPF_LINKER_VERSION}"; \
    rm -rf "$CARGO_HOME/registry" "$CARGO_HOME/git"; \
    bpf-linker --version | grep -qF " ${BPF_LINKER_VERSION}"

ENV EBPF_NIGHTLY=${EBPF_NIGHTLY}

LABEL org.opencontainers.image.title="rust-builder-ebpf" \
      org.opencontainers.image.description="False Systems eBPF build stage: rust-builder plus a dated nightly with rust-src and bpf-linker. Build-time only."
