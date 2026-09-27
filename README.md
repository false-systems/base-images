# base-images

The shared **builder** images for False Systems products: one pinned toolchain
per language, rebuilt every week, published for `linux/amd64` and
`linux/arm64`.

They are build stages only. Runtime images stay on upstream bases pinned by
digest in each product repo: `gcr.io/distroless/cc-debian13:nonroot` for Rust
services and `debian:trixie-slim` for vartio's release. The builders are
Debian 13 (trixie) too, so glibc and OpenSSL match on both sides.

| Image | Tags | Base | For |
|---|---|---|---|
| `ghcr.io/false-systems/rust-builder` | `1.97.1`, `1.97.1-YYYYMMDD` | `rust:1.97.1-slim-trixie` | ahti, cloudtrail-shipper, polku, jalki, selko |
| `ghcr.io/false-systems/rust-builder` | `1.97.1-ebpf`, `1.97.1-ebpf-YYYYMMDD` | `rust-builder:1.97.1` from the same run | jalki, selko's Linux sensor |
| `ghcr.io/false-systems/elixir-builder` | `1.19.5-otp28.5-trixie`, `…-YYYYMMDD` | `hexpm/elixir:1.19.5-erlang-28.5.0.5-debian-trixie-20260824-slim` | vartio |

Rust 1.97.1, not 1.97.0: 1.97.0 has a P-critical x86_64 miscompile
([rust-lang/rust#159035](https://github.com/rust-lang/rust/issues/159035)).

## What is in each image

**rust-builder**

- Rust 1.97.1 (minimal profile) with `rustfmt` and `clippy`, and the targets
  `x86_64-unknown-linux-gnu` and `aarch64-unknown-linux-gnu`.
- A build guard: the image does not build unless `rustc --version` equals the tag.
- Native C/C++ toolchain: `gcc`, `g++`, `make`, `clang` 19, `lld`, `cmake`,
  `pkg-config`, `protobuf-compiler` + `libprotobuf-dev` (the well-known
  `.proto` types), `libssl-dev`, `git`, `curl`.
- A cross toolchain for the other architecture: `gcc`/`g++` and the libc
  headers for x86_64 on the arm64 image, and for aarch64 on the amd64 image.
  The environment is preset, so
  `cargo build --target <x86_64|aarch64>-unknown-linux-gnu` links on either
  host with no extra flags. It covers crates that compile C or C++ through
  `cc`, such as ring and zstd.

  ```
  CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=x86_64-linux-gnu-gcc
  CC_x86_64_unknown_linux_gnu / CXX_… / AR_…  = x86_64-linux-gnu-{gcc,g++,ar}
  CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc
  CC_aarch64_unknown_linux_gnu / CXX_… / AR_… = aarch64-linux-gnu-{gcc,g++,ar}
  ```

  There are no cross `-dev` libraries, and `PKG_CONFIG_ALLOW_CROSS` is not
  set. A cross build that needs a system library (OpenSSL through `openssl-sys`,
  for example) must use rustls or a vendored build instead. Native builds can
  use `libssl-dev`.
- Prebuilt static binaries in `/usr/local/bin`, each checked against the
  sha256 its release publishes:
  - `cargo-chef` 0.1.78
  - `cargo-auditable` 0.7.6
  - `sccache` 0.18.0

  They are outside `$CARGO_HOME`, so a cache mount there cannot hide them.
- `RUSTC_WRAPPER` is **not** set. Turn sccache on per build (see below).
- rustup's auto-self-update is off. `$RUSTUP_HOME` and `$CARGO_HOME` are
  world-writable, as upstream leaves them, so a non-root build user works.

**rust-builder:…-ebpf** (everything above, plus)

- `nightly-2026-09-25` with `rust-src`, for `-Z build-std=core` against
  `bpfel-unknown-none`. This is the date jalki pins in
  `jalki-ebpf/rust-toolchain.toml`, and `$EBPF_NIGHTLY` names it.
- `bpf-linker` 0.10.4, built from crates.io with `--locked` through
  `cargo auditable`. Its default feature `rust-llvm-22` loads libLLVM at link
  time from the sysroot of the rustc that calls it: the nightly's LLVM, 23.1
  for this date. It is pinned because 0.11 needs a system LLVM through
  `llvm-config`, and that release broke every jalki build.
- The smoke test links a real BPF object with this pair. jalki's own
  `xtask build-ebpf --release` (origin/main after jalki#95) was also run in the
  image: it used the preinstalled nightly, with no toolchain download.

**elixir-builder**

- Elixir 1.19.5 on OTP 28.5 (28.5.0.5), Debian 13. The build checks both
  against the tag.
- `build-essential`, `git`, `ca-certificates`.
- Hex and rebar3 are already installed, under `MIX_HOME=/opt/mix` and
  `HEX_HOME=/opt/hex`. Both are world-writable, so they work for any `USER`
  or `HOME`. Product Dockerfiles can drop
  `mix local.hex --force && mix local.rebar --force`.

Every image runs `apt-get upgrade` at build time and is rebuilt every Monday,
so it carries that week's Debian security fixes even when the upstream digest
has not moved.

Approximate unpacked sizes (arm64): rust-builder 1.8 GB, -ebpf 2.5 GB,
elixir-builder 0.5 GB.

## Tags

- `<version>`, e.g. `rust-builder:1.97.1`, is a **moving** tag. Every build of
  `main` moves it: a push, the Monday rebuild, or a manual run.
- `<version>-YYYYMMDD` is **immutable**. A second build on the same day gets
  `-YYYYMMDD.2`, and so on. Use it to go back to one exact week.
- Each tag is a multi-arch index: one `linux/amd64` image, one `linux/arm64`
  image, and an attestation manifest for each, holding an SPDX SBOM and SLSA
  provenance (`mode=max`). `ci/publish.sh` refuses to tag an index that lacks
  any of them.

## Using them in a product Dockerfile

Pin the **moving tag plus the index digest** in a literal `FROM` line. Let
Dependabot move the digest. The tag says which toolchain the build uses, and
the digest makes the build reproducible.

```dockerfile
# Rust service, cargo-chef + sccache.
FROM ghcr.io/false-systems/rust-builder:1.97.1@sha256:<index digest> AS chef
WORKDIR /build

FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS builder
ARG TARGETARCH
ENV RUSTC_WRAPPER=sccache SCCACHE_DIR=/sccache
COPY --from=planner /build/recipe.json recipe.json
RUN --mount=type=cache,id=myrepo-cargo-registry,target=/usr/local/cargo/registry \
    --mount=type=cache,id=myrepo-sccache-${TARGETARCH},target=/sccache \
    cargo chef cook --release --locked --recipe-path recipe.json
COPY . .
RUN --mount=type=cache,id=myrepo-cargo-registry,target=/usr/local/cargo/registry \
    --mount=type=cache,id=myrepo-sccache-${TARGETARCH},target=/sccache \
    cargo auditable build --release --locked

FROM gcr.io/distroless/cc-debian13:nonroot@sha256:<digest>
COPY --from=builder /build/target/release/myservice /usr/local/bin/
```

```dockerfile
# Elixir release (vartio).
FROM ghcr.io/false-systems/elixir-builder:1.19.5-otp28.5-trixie@sha256:<index digest> AS builder
ENV MIX_ENV=prod
# ... deps.get / compile / release as today, without `mix local.hex/rebar`.
```

Get the index digest from the build's job summary, or with:

```sh
docker buildx imagetools inspect ghcr.io/false-systems/rust-builder:1.97.1 \
  --format '{{json .Manifest}}' | jq -r .digest
```

In the product repo's `.github/dependabot.yml`, the `docker` ecosystem needs
no registry credentials, because these packages are public. Let it refresh the
digest, and ignore version changes, so that the Rust version moves only
together with `rust-toolchain.toml`:

```yaml
  - package-ecosystem: docker
    directory: "/"
    schedule: { interval: weekly }
    ignore:
      - dependency-name: "ghcr.io/false-systems/rust-builder"
        update-types: ["version-update:semver-major", "version-update:semver-minor", "version-update:semver-patch"]
```

Keep `rust-toolchain.toml` at the image's version (`channel = "1.97.1"`). The
image's toolchain then satisfies it, and rustup downloads nothing.

## Bumping Rust

1. Resolve the new upstream digest:
   `docker buildx imagetools inspect rust:1.98.0-slim-trixie` (the `Digest:` line).
2. In one PR:
   - `rust/Dockerfile`: the `FROM` line (tag and digest) and the
     `RUST_BUILDER_VERSION` ARG default.
   - `docker-bake.hcl`: `RUST_BUILDER_VERSION`.
   - `rust-ebpf/Dockerfile`: the `RUST_BUILDER` ARG default (standalone builds only).
   - This README, and the Rust `ignore` in `.github/dependabot.yml` if it names a version.

   CI builds, smoke-tests and scans both architectures on the PR. If the
   `FROM` line and the tag disagree, the build guard fails it.
3. Merge. The publish job creates the new tag, e.g. `rust-builder:1.98.0`.
   The old tag stays where it is, but it is **no longer rebuilt**, so move the
   products soon.
4. In each product repo, one PR changes `rust-toolchain.toml` and the `FROM`
   line (new tag and digest) together.

Tool bumps (`cargo-chef`, `cargo-auditable`, `sccache` in `rust/Dockerfile`)
change the version ARG **and both sha256 sums**. Take the sums from the
release's `<asset>.sha256` files, and cross-check them against
`gh api repos/<owner>/<repo>/releases/tags/<tag> --jq '.assets[] | "\(.name) \(.digest)"'`.

## Bumping the eBPF nightly or bpf-linker

Change `EBPF_NIGHTLY` in `rust-ebpf/Dockerfile` in the same week as jalki's
`jalki-ebpf/rust-toolchain.toml`. The smoke test links a BPF object with the
new pair, so a nightly whose LLVM bpf-linker cannot drive fails on the PR,
before anything is published. Moving `bpf-linker` to 0.11 or later means
bringing a system LLVM (`llvm-config`) into this image first.

## Bumping Elixir or OTP

hexpm publishes a new dated tag for each rebuild; it does not re-push old
ones. Dependabot therefore rarely has a digest to move, so check for a newer
tag by hand now and then:

```sh
curl -s 'https://hub.docker.com/v2/repositories/hexpm/elixir/tags?page_size=100&name=1.19.5-erlang-28.5&ordering=last_updated' |
  jq -r '.results[] | select(.name | test("debian-trixie-.*-slim$")) | "\(.last_updated) \(.name) \(.digest)"' | head
```

Put the new tag and digest in `elixir/Dockerfile`. If the Elixir version or
the OTP major.minor changes, also change `ELIXIR_BUILDER_VERSION` and
`ELIXIR_BUILDER_OTP` in `docker-bake.hcl` and the Dockerfile ARG defaults. The
build guard checks them. Bump vartio's `.tool-versions` together with its
`FROM` line.

## Building and testing locally

```sh
docker buildx bake --load rust-builder             # native arch, tagged as in CI
docker buildx bake --load rust                     # + rust-ebpf
docker buildx bake --load elixir-builder
ci/smoke.sh rust elixir                            # the CI smoke tests
TRIVY="docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  -v trivy-cache:/root/.cache aquasec/trivy:0.74.0" ci/scan.sh rust elixir
```

On a Mac where the buildx plugin is not registered with the docker CLI, set
`BUILDX=/opt/homebrew/lib/docker/cli-plugins/docker-buildx` and call that
binary instead of `docker buildx`. Set `IMAGE_REGISTRY=local` to keep local
images away from the real tags.

## CI (`.github/workflows/build.yml`)

- **Triggers:** a push to `main` that touches the images, every Monday at
  04:00 UTC, manual dispatch, and pull requests (build and check only).
- **Build:** one job per group (`rust`, `elixir`) and architecture, on
  GitHub-hosted native runners: `ubuntu-24.04` for amd64 and
  `ubuntu-24.04-arm` for arm64. No QEMU, and no layer cache: every build
  starts from the pinned bases.
- **Checks, in order:** `bake --load`, then `ci/smoke.sh`, then `ci/scan.sh`.
  Trivy reports HIGH and CRITICAL findings in the log and the job summary. It
  **fails on any CRITICAL that has a fix**. Unfixed findings are reported but
  do not block.
- **Push:** from `main` only. Each arch is pushed by digest, with the SBOM and
  `mode=max` provenance. That build reuses every layer of the checked one.
- **Publish:** `ci/publish.sh` merges the two architectures with
  `imagetools create`, sets the moving and dated tags, verifies the index, and
  writes the digests to the job summary.
- **Permissions:** `contents: read` everywhere, and `packages: write` only in
  the jobs that push. No `id-token`: nothing is signed yet (Phase 3).
- **Pinning:** every action is pinned to a commit SHA, and Dependabot bumps the
  actions and the base digests weekly.

### Safety: public repo, hosted runners only

This repository is public so that its CI minutes are free, and so that
anyone, including a customer's air-gapped mirror, can pull its images
anonymously. That makes two rules non-negotiable:

- **Never use a self-hosted runner here.** Any pull request, from anyone, can
  change the workflow, and the org's own machines must never run that code.
  The org-level guard is the runner group's "Allow public repositories"
  setting. It must be **off** for every group that holds org runners.
- **Nothing secret in the logs.** They are public. The only credential is the
  job's own `GITHUB_TOKEN`, for `ghcr.io`.

### First publish

GHCR creates each package **private**. After the first successful run on
`main`, set `rust-builder` and `elixir-builder` to **Public** under
Org → Packages → package settings. Otherwise Dependabot, the ARC runners and
customers cannot pull them anonymously.
