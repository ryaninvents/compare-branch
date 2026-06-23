# Reproducible build environment: one image pins the Zig toolchain and
# cross-compiles every release target from a single host. Zig cross-compiles
# natively, so no per-arch runners or QEMU are needed.
#
#   docker build --target artifacts --output type=local,dest=dist .
#
# leaves one binary per target under dist/<zig-triple>/cb-bin.

FROM debian:bookworm-slim AS build
ARG ZIG_VERSION=0.14.1
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl xz-utils ca-certificates \
 && rm -rf /var/lib/apt/lists/*
RUN arch="$(uname -m)" \
 && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
 && mkdir -p /opt/zig \
 && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
 && ln -s /opt/zig/zig /usr/local/bin/zig \
 && rm /tmp/zig.tar.xz
WORKDIR /src
COPY . .
RUN zig build release

# Export-only stage: `--output type=local` copies just the binaries out.
FROM scratch AS artifacts
COPY --from=build /src/zig-out/release /
