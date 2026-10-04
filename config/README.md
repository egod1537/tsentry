# Configuration boundary

`tsentry` owns the deployment policy and small, reviewable overrides. The official
`getsentry/self-hosted` checkout under `vendor/self-hosted` owns Sentry's Compose
file, images, and generated application configuration.

The root `.env` is linked to `vendor/self-hosted/.env.custom` by
`scripts/bootstrap.sh`. Upstream loads `.env.custom` after its release-specific
`.env`, so these values override the official defaults without patching upstream:

- `SENTRY_SELF_HOSTED_VERSION`
- `SENTRY_BIND`
- `SENTRY_SYSTEM_URL_PREFIX`
- `SENTRY_EVENT_RETENTION_DAYS`
- `COMPOSE_PROFILES`

After the official installer generates `sentry/config.yml`,
`scripts/configure-url.sh` manages two policy settings in that ignored file:

- `system.url-prefix` from `SENTRY_SYSTEM_URL_PREFIX`
- `auth.allow-registration: false`

Run the script again after an installer or manual config regeneration. Do not
enable public self-registration to work around missing SMTP; create or invite
named users through an administrator-controlled process instead.

Do not put secrets in this directory. Upstream-generated files such as
`sentry/config.yml`, `sentry/sentry.conf.py`, Relay credentials, and secret volumes
remain inside the ignored upstream/runtime area and are included in cold backups.

`config/caddy/sentry.caddy` is the singleton edge route owned by this repository.
It is mounted/imported by the shared edge only after Sentry and Cloudflare Access
are ready; it is never generated into a branch-deployment route directory.

If a future customization cannot be expressed as an environment variable, add a
documented template here and apply it explicitly from a script. Do not edit or
commit a private copy of the complete upstream tree.
