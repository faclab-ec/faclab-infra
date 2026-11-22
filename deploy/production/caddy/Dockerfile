# syntax=docker/dockerfile:1

# The edge Caddy of Faclab (S8.1): the official build plus caddy-ratelimit, the module that limits
# requests by client IP (Caddy has no rate limit of its own). The module has no releases since
# v0.1.0 (2024): it is pinned to a commit. Same Caddy version in both stages
ARG CADDY_VERSION=2.11.9

FROM caddy:${CADDY_VERSION}-builder AS builder

ARG CADDY_VERSION
ARG CADDY_RATELIMIT_COMMIT=5625512f24f6f59d6f64fb3aafe5eecff0b286db
RUN xcaddy build "v${CADDY_VERSION}" \
    --with "github.com/mholt/caddy-ratelimit@${CADDY_RATELIMIT_COMMIT}"


FROM caddy:${CADDY_VERSION}-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

# The configuration is mounted by the compose file (Caddyfile and tls-*.caddy in /etc/caddy)
