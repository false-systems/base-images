# syntax=docker/dockerfile:1
#
# ghcr.io/false-systems/rust-builder:<RUST_BUILDER_VERSION>
#
# The shared BUILD stage for every Rust image and binary: the pinned stable
# toolchain, the C/C++ toolchain that -sys crates need, a cross toolchain for
# the other Linux architecture, and the prebuilt cargo tools our Dockerfiles
# use. It is never a runtime base: product images copy their binaries into
# gcr.io/distroless/cc-debian13 (pinned by digest in each product repo).
#
# Built natively for linux/amd64 and linux/arm64 by .github/workflows/build.yml
# and rebuilt every Monday, so `apt-get upgrade` below carries the week's
# Debian security fixes even when the upstream digest has not moved.
#
# The Rust version lives in docker-bake.hcl (RUST_BUILDER_VERSION), which also
# names the tag. The guard below fails the build if the FROM line and the tag
# disagree, so a tag can never carry a different compiler. See README.md,
# "Bumping Rust".
FROM rust:1.97.1-slim-trixie@sha256:8e8cf8f7fd54a2d23d5a743b3a03f56e26b6c774276c33fa0595111704ebb15c

# The tag this image is published under. Not RUST_VERSION: the upstream image
# sets ENV RUST_VERSION, and an ENV overrides an ARG of the same name, which
# would make the guard compare the base with itself.
ARG RUST_BUILDER_VERSION=1.97.1
ARG TARGETARCH
ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ── guard: rustc must be exactly the version in the tag ─────────────────────
RUN set -eu; \
    got="$(rustc --version | cut -d' ' -f2)"; \
    if [ "$got" != "$RUST_BUILDER_VERSION" ]; then \
      echo "rustc is ${got}, but this image is tagged ${RUST_BUILDER_VERSION}." >&2; \
      echo "Move the FROM line and RUST_BUILDER_VERSION in docker-bake.hcl together." >&2; \
      exit 1; \
    fi

# ── system packages ─────────────────────────────────────────────────────────
# clang/lld/cmake/pkg-config: -sys crates (ring, aws-lc-rs, zstd, rdkafka...).
# protobuf-compiler + libprotobuf-dev: tonic/prost builds that call protoc and
#   import the well-known types (google/protobuf/*.proto live in the -dev
#   package, not a Recommends once --no-install-recommends is used).
# libssl-dev: openssl-sys for the NATIVE architecture only (see README: cross
#   builds must use rustls or a vendored OpenSSL).
# Cross toolchain for the OTHER architecture: gcc/g++ plus its libc headers,
#   so `cargo build --target <other>-unknown-linux-gnu` links without QEMU.
RUN set -eux; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$arch" in \
      amd64) cross="gcc-aarch64-linux-gnu g++-aarch64-linux-gnu libc6-dev-arm64-cross" ;; \
      arm64) cross="gcc-x86-64-linux-gnu g++-x86-64-linux-gnu libc6-dev-amd64-cross" ;; \
      *) echo "unsupported architecture: ${arch}" >&2; exit 1 ;; \
    esac; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl git make xz-utils \
      g++ clang lld cmake pkg-config \
      protobuf-compiler libprotobuf-dev libssl-dev \
      ${cross}; \
    rm -rf /var/lib/apt/lists/*

# ── rustup: components and both Linux targets ───────────────────────────────
# auto-self-update off: a consumer's `rustup toolchain install` must not
# replace rustup with whatever release is current (it did in jalki's image).
# The chmod keeps the toolchain writable for a non-root build user, as
# upstream leaves it. It must stay in this RUN: in a later layer it would copy
# every file it touches into that layer again (~200 MB).
RUN set -eux; \
    rustup set auto-self-update disable; \
    rustup component add rustfmt clippy; \
    rustup target add x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu; \
    rustup show; \
    chmod -R a+w "$RUSTUP_HOME" "$CARGO_HOME"

# ── cargo tools: prebuilt static binaries, checked against pinned sha256 ────
# Each sum is the one the release publishes next to the archive
# (<asset>.sha256), and matches the asset digest GitHub reports. To move a
# version, change it and BOTH of its sums together. Installed into
# /usr/local/bin, not $CARGO_HOME/bin, so a cache mount on $CARGO_HOME cannot
# hide them.
ARG CARGO_CHEF_VERSION=0.1.78
ARG CARGO_AUDITABLE_VERSION=0.7.6
ARG SCCACHE_VERSION=0.18.0
RUN set -eu; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$arch" in \
      amd64) triple=x86_64-unknown-linux-musl; \
             chef_sum=aca691abfbfbbe00d482e0ed2249eec3091b65e96a0ce92947fb5b254d48b16d; \
             auditable_sum=42b66c852fbb9074a9ca356279a92eb753f48dde16017b8c82f48dcd05d6c856; \
             sccache_sum=45f1447fbe231e3037bde351ef70677dd212216c8d62ae7ca409fecc4d6acc89 ;; \
      arm64) triple=aarch64-unknown-linux-musl; \
             chef_sum=cd59b90fce5fa84c4189648fec33404ec5491791eebdb812df5e7fca8336408d; \
             auditable_sum=57265fbd87e9277fbd850c74177d17e5a6f51f15e2803643db65c187b0d4feda; \
             sccache_sum=2b3284d5da3b46a47dc4229e75bb7b88ac4aa99c8d754fb7d2f84997e5a4354a ;; \
      *) echo "unsupported architecture: ${arch}" >&2; exit 1 ;; \
    esac; \
    tmp="$(mktemp -d)"; \
    fetch() { \
      curl -fsSL --retry 3 --proto '=https' --tlsv1.2 -o "${tmp}/$3" "$1"; \
      echo "$2  ${tmp}/$3" | sha256sum -c -; \
    }; \
    fetch "https://github.com/LukeMathWalker/cargo-chef/releases/download/v${CARGO_CHEF_VERSION}/cargo-chef-${triple}.tar.xz" \
      "$chef_sum" chef.tar.xz; \
    tar -xJf "${tmp}/chef.tar.xz" -C /usr/local/bin --strip-components=1 \
      "cargo-chef-${triple}/cargo-chef"; \
    fetch "https://github.com/rust-secure-code/cargo-auditable/releases/download/v${CARGO_AUDITABLE_VERSION}/cargo-auditable-${triple}.tar.xz" \
      "$auditable_sum" auditable.tar.xz; \
    tar -xJf "${tmp}/auditable.tar.xz" -C /usr/local/bin --strip-components=1 \
      "cargo-auditable-${triple}/cargo-auditable"; \
    fetch "https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VERSION}/sccache-v${SCCACHE_VERSION}-${triple}.tar.gz" \
      "$sccache_sum" sccache.tar.gz; \
    tar -xzf "${tmp}/sccache.tar.gz" -C /usr/local/bin --strip-components=1 \
      "sccache-v${SCCACHE_VERSION}-${triple}/sccache"; \
    rm -rf "$tmp"; \
    chown root:root /usr/local/bin/cargo-chef /usr/local/bin/cargo-auditable /usr/local/bin/sccache; \
    chmod 0755 /usr/local/bin/cargo-chef /usr/local/bin/cargo-auditable /usr/local/bin/sccache; \
    cargo chef --version | grep -qF " ${CARGO_CHEF_VERSION}"; \
    sccache --version | grep -qF " ${SCCACHE_VERSION}"; \
    # cargo-auditable prints cargo's version, not its own; its pinned sum is
    # the version check. This proves it runs.
    cargo auditable --version >/dev/null

# ── cross environment ───────────────────────────────────────────────────────
# Both triples are set on both architectures. For the native one the names
# resolve to the native gcc/g++/ar (Debian ships the triple-prefixed names),
# so a build for either target works the same way on either host. cc-rs reads
# CC_/CXX_/AR_<triple>; cargo reads CARGO_TARGET_<TRIPLE>_LINKER.
# Not set: PKG_CONFIG_ALLOW_CROSS. There are no cross -dev libraries here, so
# letting pkg-config answer for the other target would hand it host libraries.
ENV CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=x86_64-linux-gnu-gcc \
    CC_x86_64_unknown_linux_gnu=x86_64-linux-gnu-gcc \
    CXX_x86_64_unknown_linux_gnu=x86_64-linux-gnu-g++ \
    AR_x86_64_unknown_linux_gnu=x86_64-linux-gnu-ar \
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc \
    CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc \
    CXX_aarch64_unknown_linux_gnu=aarch64-linux-gnu-g++ \
    AR_aarch64_unknown_linux_gnu=aarch64-linux-gnu-ar

# Every tool named above must exist on this architecture.
RUN set -eu; \
    for tool in x86_64-linux-gnu-gcc x86_64-linux-gnu-g++ x86_64-linux-gnu-ar \
                aarch64-linux-gnu-gcc aarch64-linux-gnu-g++ aarch64-linux-gnu-ar \
                clang ld.lld cmake pkg-config protoc git; do \
      command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 1; }; \
    done

LABEL org.opencontainers.image.title="rust-builder" \
      org.opencontainers.image.description="False Systems Rust build stage: pinned stable Rust, clang/lld/cmake/protoc, amd64<->arm64 cross toolchain, cargo-chef, cargo-auditable, sccache. Build-time only." \
      org.opencontainers.image.version="${RUST_BUILDER_VERSION}"
