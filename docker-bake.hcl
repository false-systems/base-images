# The one place that names the images, their tags and the versions in them.
#
#   docker buildx bake --load rust-builder      # native arch, loaded locally
#   docker buildx bake --load rust              # rust-builder + rust-ebpf
#   docker buildx bake --print                  # show the resolved definition
#
# CI (.github/workflows/build.yml) builds one group per architecture, scans,
# smoke-tests, pushes by digest and then merges the tags with
# ci/publish.sh, which reads the tags from here.
#
# Every variable can be overridden from the environment by the same name, which
# is why the names are specific (GITHUB_SHA is meant to come from Actions).

variable "IMAGE_REGISTRY" {
  default = "ghcr.io/false-systems"
}

# Must equal the rustc in rust/Dockerfile's FROM line; the image guard checks.
variable "RUST_BUILDER_VERSION" {
  default = "1.97.1"
}

# Must match elixir/Dockerfile's FROM line (Elixir exact, OTP major.minor).
variable "ELIXIR_BUILDER_VERSION" {
  default = "1.19.5"
}

variable "ELIXIR_BUILDER_OTP" {
  default = "28.5"
}

variable "GITHUB_SHA" {
  default = ""
}

# CI's push step sets PUSH_BY_DIGEST=true: each image is then pushed untagged,
# by digest, to its repository, and ci/publish.sh tags the merged multi-arch
# index. BuildKit refuses a push by digest of a tagged name, so the tags are
# dropped in that mode. Otherwise (local builds, --load, --print) the tag is
# the image's name.
variable "PUSH_BY_DIGEST" {
  default = false
}

function "tags_for" {
  params = [repo, tag]
  result = PUSH_BY_DIGEST ? [] : ["${IMAGE_REGISTRY}/${repo}:${tag}"]
}

function "output_for" {
  params = [repo]
  result = PUSH_BY_DIGEST ? ["type=image,name=${IMAGE_REGISTRY}/${repo},push-by-digest=true,name-canonical=true,push=true"] : []
}

group "default" {
  targets = ["rust-builder", "rust-ebpf", "elixir-builder"]
}

group "rust" {
  targets = ["rust-builder", "rust-ebpf"]
}

group "elixir" {
  targets = ["elixir-builder"]
}

target "_common" {
  labels = {
    "org.opencontainers.image.source"   = "https://github.com/false-systems/base-images"
    "org.opencontainers.image.vendor"   = "False Systems"
    "org.opencontainers.image.revision" = GITHUB_SHA
  }
}

target "rust-builder" {
  inherits = ["_common"]
  context  = "rust"
  args = {
    RUST_BUILDER_VERSION = RUST_BUILDER_VERSION
  }
  tags   = tags_for("rust-builder", RUST_BUILDER_VERSION)
  output = output_for("rust-builder")
}

# Built FROM the rust-builder target of the same invocation, never from a
# registry copy, so rust-builder:X and rust-builder:X-ebpf cannot diverge.
target "rust-ebpf" {
  inherits = ["_common"]
  context  = "rust-ebpf"
  contexts = {
    rust-builder = "target:rust-builder"
  }
  args = {
    RUST_BUILDER = "rust-builder"
  }
  tags   = tags_for("rust-builder", "${RUST_BUILDER_VERSION}-ebpf")
  output = output_for("rust-builder")
}

target "elixir-builder" {
  inherits = ["_common"]
  context  = "elixir"
  args = {
    ELIXIR_BUILDER_VERSION = ELIXIR_BUILDER_VERSION
    ELIXIR_BUILDER_OTP     = ELIXIR_BUILDER_OTP
  }
  tags   = tags_for("elixir-builder", "${ELIXIR_BUILDER_VERSION}-otp${ELIXIR_BUILDER_OTP}-trixie")
  output = output_for("elixir-builder")
}
