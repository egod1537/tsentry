# Singleton edge route

`sentry.caddy` is owned by `tsentry`; it must not be generated into the Trasolve
branch-deployment route directory.

The existing edge Caddy can reach an OrbStack host service bound to
`127.0.0.1:9000` through `host.docker.internal:9000`. This keeps Sentry and the
edge on separate Docker networks. Caddy's reverse proxy supports WebSocket and
streaming responses without a special upgrade-header rule, and this route does
not configure request buffering or a body-size limit.

Do not activate this route until:

1. `scripts/preflight.sh` and Sentry installation have succeeded.
2. Local `/_health/` succeeds.
3. A Cloudflare Access self-hosted application and Allow policy protect the
   exact hostname.
4. The edge integration steps in `docs/external-access.md` are reviewed.

