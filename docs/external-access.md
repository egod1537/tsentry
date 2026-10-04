# Domain, TLS, and external access

## 현재 조사 결과

2026-10-04 기준 hostname 후보는 `sentry.mangagaki.net`이다.

- public DNS는 이 hostname과 임의의 다른 subdomain을 같은 Cloudflare anycast 주소로
  해석한다. 이는 기존 wildcard DNS 동작이다.
- 실행 중인 `jjs` tunnel(`678279aa-d007-4d03-86ed-bd1d084873f4`)의 ingress에는
  `*.mangagaki.net -> http://caddy:80` 규칙이 있다.
- `jjs.mangagaki.net`과 기존 branch route는 HTTP 200으로 동작한다.
- `sentry.mangagaki.net`은 아직 Caddy host route가 없어 Cloudflare HTTP 502를 반환한다.
- unauthenticated 요청에서 Cloudflare Access redirect/cookie가 관찰되지 않았다.
- account에는 여러 tunnel이 있지만 이 hostname을 위해 새 tunnel을 만들 이유는 없다.

따라서 **기존 jjs tunnel + 기존 edge Caddy**를 재사용한다. DNS의 개별 record 존재
여부는 public proxied 응답만으로 완전히 구분할 수 없지만, wildcard와 동일한 DNS/응답,
local ingress match를 종합하면 기존 wildcard route에 잡힌 것으로 판단된다. Cloudflare
dashboard에서 exact hostname record 충돌이 없는지 최종 확인한다.

## 목표 구조

```text
Internet
  -> Cloudflare TLS
  -> Cloudflare Access (exact hostname policy)
  -> existing jjs Cloudflare Tunnel
  -> existing edge Caddy (exact Host route)
  -> host.docker.internal:9000
  -> SENTRY_BIND=127.0.0.1:9000
```

OrbStack에서 edge Caddy container가 `host.docker.internal`을 통해 host loopback에만
bind된 test origin에 접근할 수 있음을 확인했다. 따라서 Caddy를 Sentry Compose network에
추가하지 않고 network 격리를 유지한다.

## 1. Cloudflare Access를 먼저 구성

Cloudflare Zero Trust에서 exact hostname을 대상으로 Self-hosted application을 만든다.

- Application hostname: `sentry.mangagaki.net`
- Policy: 기존 내부 도구용 private policy가 있으면 재사용
- 없다면 승인된 email/domain/group만 포함하는 Allow policy 생성
- Session duration과 MFA는 기존 내부 운영 도구 정책에 맞춤
- 가능하면 tunnel route의 `Protect with Access`도 활성화하여 origin에서 token 검증

Access application은 deny-by-default이므로 Allow 대상이 명시되어야 한다. 허용할
email/domain/group이 결정되지 않은 상태에서는 Caddy route를 활성화하지 않는다.

### SDK ingest 예외

hostname 전체에 Access login을 강제하면 Sentry SDK의 event 전송도 Access redirect에
막힌다. DSN ingest endpoint는 사용자 UI가 아니므로 public path override 또는 더 구체적인
Bypass application을 다음처럼 **최소 범위**로 둔다.

- 현대 SDK 필수: `/api/*/envelope/`
- legacy SDK를 실제 사용하는 경우에만: `/api/*/store/`와 `/api/store/`

Cloudflare는 더 구체적인 path rule을 우선한다. `/api/0/*` 전체나 `/api/*` 전체를
bypass하지 않는다. 그러면 UI/admin API와 artifact API는 Access 뒤에 남고, SDK ingest만
DSN public key를 사용해 Relay로 전달된다. Bypass path는 Access 인증/로그가 적용되지
않으므로 Cloudflare/Sentry rate limiting과 event 유입량을 관찰한다.

source map/artifact upload는 `/api/0/...`을 사용하므로 Access를 우회하지 않는다. CI가
외부 hostname으로 업로드해야 한다면 별도 Cloudflare Service Auth policy와 짧게 관리되는
service token을 사용한다. Access application의 single-header service token 기능을
`X-CF-Access-Token` 같은 전용 header로 설정하면, `sentry-cli`의 단일 custom header와
Sentry의 `Authorization` auth token을 동시에 사용할 수 있다. 두 token은 backend CI
secret store에만 두며 frontend bundle에는 전달하지 않는다.

```bash
./scripts/check-edge-readiness.sh
```

현재는 Access와 backend가 없어 이 검사가 실패하는 것이 정상이다.

## 2. Sentry canonical URL

root `.env`는 다음 값을 사용한다.

```dotenv
SENTRY_BIND=127.0.0.1:9000
SENTRY_SYSTEM_URL_PREFIX=https://sentry.mangagaki.net
```

`bootstrap.sh`와 `update.sh`는 official installer가 만든 ignored
`vendor/self-hosted/sentry/config.yml`에 다음 값을 적용한다.

```yaml
system.url-prefix: 'https://sentry.mangagaki.net'
```

수동 재적용이 필요하면:

```bash
./scripts/configure-url.sh
./scripts/start.sh
```

이 설정은 UI/email 링크와 generated DSN의 public origin을 결정한다. 내부 container간
통신용 `system.internal-url-prefix: http://web:9000`은 변경하지 않는다.

## 3. singleton Caddy route 활성화

route source는 [sentry.caddy](../config/caddy/sentry.caddy)이며 Trasolve branch route
generator가 관리하는 `~/.local/state/jjs/routes`에 복사하지 않는다.

Sentry local health와 Access gate가 준비된 maintenance window에서 shared edge Compose의
`caddy` volume에 다음 read-only mount를 추가한다.

```yaml
- /Users/yang/proj/tsentry/config/caddy:/etc/caddy/tsentry:ro
```

그리고 `/Users/yang/proj/trasolve/infra/edge/Caddyfile`의 global block 다음에 singleton
import를 추가하되 기존 branch import와 분리한다.

```caddyfile
import /etc/caddy/tsentry/*.caddy
import /etc/caddy/routes/*.caddy
```

두 변경은 같은 maintenance 작업에서 적용한다. live Caddyfile만 먼저 바꾸면 아직 mount가
없는 container의 healthcheck가 실패할 수 있다. 변경 전후에 `caddy validate`를 실행하고
edge Caddy만 recreate/reload한다. Cloudflared나 branch application container는 재시작하지
않는다. 현재 backend와 Access가 준비되지 않았으므로 이 shared-edge 변경은 아직 적용하지
않았다.

Caddy `reverse_proxy`는 WebSocket을 기본 지원하고 SSE response도 content type에 따라
flush한다. route는 request buffering이나 body-size 제한을 추가하지 않으며 원래 Host와
`X-Forwarded-Host`, external `https` scheme/port를 upstream에 전달한다.

Cloudflare 자체 upload 한도는 plan에 따라 Free/Pro 100 MB, Business 200 MB이므로 큰
artifact가 있다면 실제 plan/zone의 Maximum Upload Size를 확인한다. 제한을 우회하기 위해
9000 포트를 공개하지 말고 artifact를 chunk하거나 plan/limit을 검토한다.

## 4. 계정 보안

- admin password는 password manager에서 생성한 강한 값을 사용한다.
- `scripts/configure-url.sh`가 적용한 `auth.allow-registration: false`와 비로그인 화면의
  공개 가입 차단을 함께 확인한다.
- SMTP가 필요하지 않으면 dummy/default 개발 구성을 억지로 외부 SMTP와 연결하지 않는다.
- Sentry system secret, Cloudflare credential, Access service token, admin/auth token은 Git에
  저장하지 않는다.
- DSN은 SDK에 배포되는 project 식별/ingest URL이며 admin credential과 동일한 secret이
  아니다. 그래도 불필요한 공개와 Git 기록은 피한다.
- 관리자/auth token과 Cloudflare Access service-token secret은 frontend 환경변수에 넣지
  않는다.

## 5. Smoke test

자동 확인:

```bash
./scripts/check-edge-readiness.sh
./scripts/smoke-external.sh
```

Access service token으로 origin까지 자동 검사할 때만 terminal session에 비공개로 설정한다.

```bash
export CF_ACCESS_CLIENT_ID=...
export CF_ACCESS_CLIENT_SECRET=...
./scripts/smoke-external.sh
unset CF_ACCESS_CLIENT_ID CF_ACCESS_CLIENT_SECRET
```

token 값을 command history나 `.env`에 저장하지 않는다. 최종 browser/manual 점검:

1. unauthenticated private browser에서 Cloudflare Access가 먼저 나타난다.
2. Access 인증 후 Sentry login page가 HTTPS로 로드된다.
3. admin login과 organization/project 이동이 정상이다.
4. browser console에 mixed-content 오류가 없다.
5. project DSN이 `https://sentry.mangagaki.net/...`을 사용한다.
6. test error가 수집된다.
7. unauthenticated SDK envelope가 Access login으로 redirect되지 않고 Relay에 도달한다.
8. backend 전용 Sentry auth token과 Cloudflare Service Auth token으로 작은
   source map/artifact를 업로드한다.
9. plan 한도에 근접한 representative artifact도 확인하며 413/timeout이 없는지 본다.

로그인과 project가 아직 준비되지 않았으므로 이 smoke test는 현재 완료 상태가 아니다.
