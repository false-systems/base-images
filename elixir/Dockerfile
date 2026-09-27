# ghcr.io/false-systems/elixir-builder:<ELIXIR_BUILDER_VERSION>-otp<ELIXIR_BUILDER_OTP>-trixie
#
# The shared BUILD stage for Elixir releases (vartio): hexpm's Elixir/OTP on
# Debian 13 plus a C toolchain for NIFs, git for git deps, and Hex and rebar3
# already installed. Never a runtime base. A release built here needs
# trixie's glibc and OpenSSL (beam.smp needs GLIBC_2.38, crypto.so
# OPENSSL_3.4.0), so it must run on debian:trixie-slim, never bookworm: move a
# product's runtime stage to trixie in the same PR that moves it onto this
# image (README.md, "Runtime pairing").
#
# Rebuilt every Monday by .github/workflows/build.yml, so `apt-get upgrade`
# carries the week's Debian fixes. hexpm publishes a NEW dated tag rather than
# re-pushing an old one, so moving to a newer hexpm build is a hand edit of the
# FROM line (README.md, "Bumping Elixir or OTP").
#
# No `# syntax=` line, on purpose: BuildKit's built-in Dockerfile frontend
# parses this file, so both bake runs in a CI job (test, then push) see the
# same frontend and nothing mutable is pulled to parse it.
FROM hexpm/elixir:1.19.5-erlang-28.5.0.5-debian-trixie-20260824-slim@sha256:fc48687e842380e285030fedd6c3625c2333a72fab58d670699414dd2d5222a9

# The versions in the tag (docker-bake.hcl). The guard checks the base against
# them: Elixir exactly, OTP by the "major.minor" the tag names.
ARG ELIXIR_BUILDER_VERSION=1.19.5
ARG ELIXIR_BUILDER_OTP=28.5
ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN set -eu; \
    elixir="$(elixir --short-version)"; \
    otp="$(erl -noshell -eval 'io:format("~s", [string:trim(element(2, file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"]))))]), halt().')"; \
    echo "Elixir ${elixir}, OTP ${otp}"; \
    if [ "$elixir" != "$ELIXIR_BUILDER_VERSION" ]; then \
      echo "Elixir is ${elixir}, but this image is tagged ${ELIXIR_BUILDER_VERSION}." >&2; exit 1; \
    fi; \
    case "$otp" in \
      "${ELIXIR_BUILDER_OTP}" | "${ELIXIR_BUILDER_OTP}".*) ;; \
      *) echo "OTP is ${otp}, but this image is tagged otp${ELIXIR_BUILDER_OTP}." >&2; exit 1 ;; \
    esac

RUN set -eux; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends build-essential ca-certificates git; \
    rm -rf /var/lib/apt/lists/*

# Hex and rebar3 under fixed, world-readable paths rather than /root/.mix, so
# they are found whatever HOME or USER a product build runs with. A product
# Dockerfile no longer needs its own
# `mix local.hex --force && mix local.rebar --force`.
#
# Both are pinned, so a weekly rebuild cannot change them without a diff here:
# - Hex by version. `mix local.hex <version>` checks the download against the
#   sha512 in hex.pm's signed index.
# - rebar3 by URL and sha512, both from https://builds.hex.pm/installs/rebar.csv
#   (columns: version, sha512, Elixir build, OTP major); the file lives at
#   /installs/<Elixir build>/rebar3-<version>-otp-<OTP major>. The options
#   must come before `rebar3 <url>`.
# Bumping OTP's major or Elixir means checking both against those indexes
# (README.md, "Bumping Elixir or OTP").
ARG HEX_VERSION=2.5.1
ARG REBAR3_VERSION=3.25.1
ARG REBAR3_URL=https://builds.hex.pm/installs/1.18.4/rebar3-3.25.1-otp-28
ARG REBAR3_SHA512=992fd755b7926fae455e5e07d9d195f4d3e7f181609eed1b9cabfe548624df10d148cd4b59bda40bebb185d3d68f9a9fd68a70b294101c8ad9cf0fadcc683d24
ENV MIX_HOME=/opt/mix \
    HEX_HOME=/opt/hex
RUN set -eux; \
    mix local.hex "$HEX_VERSION" --force; \
    mix local.rebar --sha512 "$REBAR3_SHA512" --force rebar3 "$REBAR3_URL"; \
    hex="$(mix hex.info | awk '$1 == "Hex:" { print $2 }')"; \
    [ "$hex" = "$HEX_VERSION" ] || { echo "Hex is ${hex}, not ${HEX_VERSION}" >&2; exit 1; }; \
    rebar="$("$MIX_HOME"/elixir/*/rebar3 version)"; \
    case "$rebar" in \
      "rebar ${REBAR3_VERSION} "*) ;; \
      *) echo "${rebar}, not rebar ${REBAR3_VERSION}" >&2; exit 1 ;; \
    esac; \
    chmod -R a+rwX "$MIX_HOME" "$HEX_HOME"

LABEL org.opencontainers.image.title="elixir-builder" \
      org.opencontainers.image.description="False Systems Elixir build stage: Elixir and OTP on Debian 13 with build-essential, git, Hex and rebar3. Build-time only." \
      org.opencontainers.image.version="${ELIXIR_BUILDER_VERSION}-otp${ELIXIR_BUILDER_OTP}-trixie"
