# syntax=docker/dockerfile:1
#
# ghcr.io/false-systems/elixir-builder:<ELIXIR_BUILDER_VERSION>-otp<ELIXIR_BUILDER_OTP>-trixie
#
# The shared BUILD stage for Elixir releases (vartio): hexpm's Elixir/OTP on
# Debian 13 plus a C toolchain for NIFs, git for git deps, and Hex and rebar3
# already installed. Never a runtime base: a release runs on
# debian:trixie-slim (pinned by digest in the product repo), which matches
# this image's glibc and OpenSSL because both are trixie.
#
# Rebuilt every Monday by .github/workflows/build.yml, so `apt-get upgrade`
# carries the week's Debian fixes. hexpm publishes a NEW dated tag rather than
# re-pushing an old one, so moving to a newer hexpm build is a hand edit of the
# FROM line (README.md, "Bumping Elixir or OTP").
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
# they are found whatever HOME or USER a product build runs with. Both
# installers verify what they download (Hex: signed by hex.pm; rebar3: the
# checksum hex.pm publishes). A product Dockerfile no longer needs its own
# `mix local.hex --force && mix local.rebar --force`.
ENV MIX_HOME=/opt/mix \
    HEX_HOME=/opt/hex
RUN set -eux; \
    mix local.hex --force; \
    mix local.rebar --force; \
    mix hex.info; \
    chmod -R a+rwX "$MIX_HOME" "$HEX_HOME"

LABEL org.opencontainers.image.title="elixir-builder" \
      org.opencontainers.image.description="False Systems Elixir build stage: Elixir and OTP on Debian 13 with build-essential, git, Hex and rebar3. Build-time only." \
      org.opencontainers.image.version="${ELIXIR_BUILDER_VERSION}-otp${ELIXIR_BUILDER_OTP}-trixie"
