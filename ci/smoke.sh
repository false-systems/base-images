#!/usr/bin/env bash
# Smoke-tests locally loaded builder images before anything is pushed.
#
#   ci/smoke.sh rust            # rust-builder and rust-ebpf
#   ci/smoke.sh elixir          # elixir-builder
#   ci/smoke.sh rust-builder    # one target
#
# The images must already be loaded under their docker-bake.hcl tags
# (`docker buildx bake --load <group>`). Each test runs in the image's native
# architecture, which is the runner's.
#
#   rust-builder  versions; native build with a C and a C++ file through cc,
#                 run; the same build for the OTHER Linux arch, with the ELF
#                 machine checked; sccache as RUSTC_WRAPPER; cargo auditable;
#                 cargo chef prepare/cook; a non-root build.
#   rust-ebpf     the nightly with rust-src; a no_std program built for
#                 bpfel-unknown-none with -Z build-std=core and linked by
#                 bpf-linker (the nightly's LLVM), ELF machine checked.
#   elixir-builder  versions; a mix project with a Hex dep (jason) and a
#                 rebar3 dep (telemetry) fetched, compiled and released, as a
#                 non-root user.
set -euo pipefail
# shellcheck source=ci/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -gt 0 ] || { echo "usage: $0 <bake target or group>..." >&2; exit 2; }

work="$(mktemp -d)"
containers=()
cleanup() {
  # ${a[@]+...}: an empty array under set -u, even in the Mac's bash 3.2.
  for c in ${containers[@]+"${containers[@]}"}; do
    docker rm -f "$c" >/dev/null 2>&1 || true
  done
  rm -rf "$work"
}
trap cleanup EXIT

# elf_machine <file>: prints x86-64, aarch64, bpf or the raw e_machine value.
elf_machine() {
  local m
  m="$(od -An -t u2 -j 18 -N 2 "$1" | tr -d ' ')"
  case "$m" in
    62) echo x86-64 ;;
    183) echo aarch64 ;;
    247) echo bpf ;;
    *) echo "e_machine=$m" ;;
  esac
}

# run_in <image> <script> [docker run args...]: runs a bash script in a new
# named container, which is kept (in $container) so files can be copied out,
# and removed on exit. Not called in $(...): errexit and the array must hold.
container=""
run_in() {
  local image=$1 script=$2
  shift 2
  container="bi-smoke-$$-${#containers[@]}"
  containers+=("$container")
  docker run --name "$container" "$@" "$image" bash -euo pipefail -c "$script"
}

smoke_rust_builder() {
  local ref=$1 native other
  native="$(docker run --rm "$ref" uname -m)"
  case "$native" in
    x86_64) other=aarch64 ;;
    aarch64) other=x86_64 ;;
    *) echo "unexpected arch $native" >&2; return 1 ;;
  esac
  echo "== rust-builder ($native, cross to $other): $ref"
  run_in "$ref" "$(cat <<'BODY'
echo "-- versions"
rustc --version; cargo --version; rustfmt --version; cargo clippy --version
cargo chef --version; sccache --version
clang --version | head -n1; ld.lld --version; cmake --version | head -n1; protoc --version
rustup target list --installed

echo "-- project with C and C++ through cc"
mkdir -p /work && cd /work
cargo new -q --vcs none hello && cd hello
mkdir csrc
printf 'int add_c(int a, int b) { return a + b; }\n' > csrc/add.c
printf 'extern "C" int mul_cxx(int a, int b) { return a * b; }\n' > csrc/mul.cpp
cat >> Cargo.toml <<'EOF'

[build-dependencies]
cc = "1"
EOF
cat > build.rs <<'EOF'
fn main() {
    cc::Build::new().file("csrc/add.c").compile("addc");
    cc::Build::new().cpp(true).file("csrc/mul.cpp").compile("mulcxx");
}
EOF
cat > src/main.rs <<'EOF'
unsafe extern "C" {
    fn add_c(a: i32, b: i32) -> i32;
    fn mul_cxx(a: i32, b: i32) -> i32;
}
fn main() {
    let (s, p) = unsafe { (add_c(2, 3), mul_cxx(2, 3)) };
    println!("hello {s} {p}");
}
EOF

echo "-- native build and run"
cargo build -q --release
test "$(./target/release/hello)" = "hello 5 6"

echo "-- cross build for ${other}-unknown-linux-gnu"
cargo build -q --release --target "${other}-unknown-linux-gnu"

echo "-- sccache as RUSTC_WRAPPER"
RUSTC_WRAPPER=sccache SCCACHE_DIR=/work/sccache cargo build -q --release --target-dir /work/t-sccache
SCCACHE_DIR=/work/sccache sccache --show-stats | tee /work/sccache-stats
grep -Eq '^Compile requests +[1-9]' /work/sccache-stats
SCCACHE_DIR=/work/sccache sccache --stop-server >/dev/null

echo "-- cargo auditable"
cargo auditable build -q --release --target-dir /work/t-auditable
readelf -S /work/t-auditable/release/hello | grep -q '\.dep-v0'

echo "-- cargo chef"
cargo chef prepare --recipe-path /work/recipe.json
cargo chef cook --release --recipe-path /work/recipe.json --target-dir /work/t-chef
BODY
)" -e "other=${other}"
  docker cp -q "${container}:/work/hello/target/${other}-unknown-linux-gnu/release/hello" "$work/hello-${other}"
  local want got
  want="$( [ "$other" = x86_64 ] && echo x86-64 || echo aarch64 )"
  got="$(elf_machine "$work/hello-${other}")"
  if command -v file >/dev/null; then file "$work/hello-${other}"; fi
  [ "$got" = "$want" ] || { echo "cross binary is $got, want $want" >&2; return 1; }

  echo "-- non-root build (uid 10001, HOME=/tmp)"
  run_in "$ref" 'cd /tmp && cargo new -q --vcs none nr && cd nr && printf "\n[build-dependencies]\ncc = \"1\"\n" >> Cargo.toml && printf "fn main() {}\n" > build.rs && cargo build -q && ./target/debug/nr' \
    --user 10001:10001 -e HOME=/tmp
  echo "rust-builder OK"
}

smoke_rust_ebpf() {
  local ref=$1 got
  echo "== rust-ebpf: $ref"
  run_in "$ref" "$(cat <<'BODY'
echo "-- versions"
rustc --version
bpf-linker --version
rustc +"$EBPF_NIGHTLY" -vV
rustup component list --toolchain "$EBPF_NIGHTLY" --installed | grep -q '^rust-src'

echo "-- no_std program for bpfel-unknown-none"
mkdir -p /work && cd /work
cargo new -q --vcs none probe && cd probe
cat >> Cargo.toml <<'EOF'

[profile.dev]
panic = "abort"

[profile.release]
panic = "abort"
EOF
cat > src/main.rs <<'EOF'
#![no_std]
#![no_main]

#[unsafe(no_mangle)]
#[unsafe(link_section = "xdp")]
pub fn probe(_ctx: *mut u8) -> u32 {
    2
}

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    loop {}
}
EOF
cargo +"$EBPF_NIGHTLY" build -q --release --target bpfel-unknown-none -Z build-std=core
BODY
)"
  docker cp -q "${container}:/work/probe/target/bpfel-unknown-none/release/probe" "$work/probe.bpf"
  if command -v file >/dev/null; then file "$work/probe.bpf"; fi
  got="$(elf_machine "$work/probe.bpf")"
  [ "$got" = bpf ] || { echo "eBPF object is $got, want bpf" >&2; return 1; }
  echo "rust-ebpf OK"
}

smoke_elixir_builder() {
  local ref=$1
  echo "== elixir-builder: $ref"
  run_in "$ref" 'elixir --version; mix hex.info; gcc --version | head -n1; make --version | head -n1; git --version'
  echo "-- mix project with Hex and rebar3 deps, non-root (uid 10001, HOME=/tmp)"
  run_in "$ref" "$(cat <<'BODY'
cd /tmp
mix new hello >/dev/null
cd hello
cat > mix.exs <<'EOF'
defmodule Hello.MixProject do
  use Mix.Project

  def project do
    [app: :hello, version: "0.1.0", elixir: "~> 1.19", deps: deps()]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [{:jason, "~> 1.4"}, {:telemetry, "~> 1.3"}]
  end
end
EOF
export MIX_ENV=prod
mix deps.get
mix compile
mix release --quiet
_build/prod/rel/hello/bin/hello eval 'IO.puts(Jason.encode!(%{ok: :telemetry.module_info(:module)}))'
BODY
)" --user 10001:10001 -e HOME=/tmp
  echo "elixir-builder OK"
}

refs="$(bake_refs "$@")"
[ -n "$refs" ] || { echo "no bake targets for: $*" >&2; exit 2; }
while read -r target ref; do
  case "$target" in
    rust-builder) smoke_rust_builder "$ref" ;;
    rust-ebpf) smoke_rust_ebpf "$ref" ;;
    elixir-builder) smoke_elixir_builder "$ref" ;;
    *) echo "no smoke test for $target" >&2; exit 1 ;;
  esac
  summary "- smoke OK: \`${target}\` (\`${ref}\`)"
done <<< "$refs"
