# 보안과 데이터 최소화

이 인스턴스는 내부 개발 도구지만 실제 request와 사용자 문맥을 받을 수 있다. 외부
접근은 Cloudflare Access와 Sentry 로그인을 겹쳐 보호하고, Sentry에 들어오는 데이터
자체도 필요한 최소 범위로 제한한다.

## 계정과 가입

- 초기 superuser 비밀번호는 script, `.env`, shell history에 넣지 않고 대화형으로
  생성한다.
- 공용 admin 계정을 일상적으로 공유하지 않는다. 가능한 경우 개인별 계정과 최소
  organization role을 사용하고, superuser는 복구 작업에만 사용한다.
- `scripts/configure-url.sh`가 생성된 `sentry/config.yml`에
  `auth.allow-registration: false`를 강제한다. upgrade 후에도 이 script가 다시
  적용되며, 외부 비로그인 창에서 임의 가입 화면이 열리지 않는지 확인한다. 이 option은
  pinned Sentry `26.9.0`의
  [공식 option registry](https://github.com/getsentry/sentry/blob/26.9.0/src/sentry/options/defaults.py)에
  존재한다.
- 사용자 추가가 필요하면 관리자가 명시적으로 계정을 만들거나 초대한다. SMTP가 없는
  환경에서는 초대/비밀번호 복구 동작을 먼저 시험하고, 편의를 위해 공개 가입을 켜지
  않는다.
- 퇴사·역할 변경 시 organization membership, personal token, Cloudflare Access
  policy를 함께 회수한다.

## DSN과 token의 구분

| 값 | 성격 | 저장 위치 |
|---|---|---|
| Project DSN | event 수집 주소와 public key가 포함된 식별자. 브라우저 SDK에 노출될 수 있음 | 앱의 환경별 설정 |
| Sentry organization/internal integration token | Sentry API 권한을 가진 secret | backend CI의 secret store만 |
| Sentry personal token | 특정 사용자 권한을 가진 secret | 불가피한 개인 작업에만 임시 사용 |
| Cloudflare Access service token | edge 접근을 통과하는 secret | backend CI의 secret store만 |
| Sentry system secret/admin password | instance 전체에 영향이 큰 secret | Mac mini의 무시된 설정 또는 password manager |

DSN을 비밀번호처럼 취급할 필요는 없지만, 허용되지 않은 event 유입을 줄이기 위해
환경별 project를 구분하고 rate limit/inbound filter를 사용한다. 반대로 admin/auth
token은 DSN과 달리 frontend bundle, client-visible 환경변수, Git, issue, log에 절대
넣지 않는다.

token은 [공식 권한 표](https://docs.sentry.io/api/permissions/)에서 작업에 필요한 최소
scope만 부여한다. source map/release 자동화는 별도
internal integration token으로 격리하고, 운영자 personal/admin token을 재사용하지
않는다. Sentry admin/auth token을 Trasolve frontend 환경변수나 bundle에 절대 전달하지
않는다.

### Auth token 회전

1. token의 소유자, 사용 위치, scope, 마지막 사용 목적을 확인한다.
2. 같은 용도의 새 internal integration token을 최소 scope로 만든다.
3. backend CI secret store에 새 값을 등록한다. terminal에서 시험할 때는 history에
   값을 남기지 않는다.
4. source map upload 또는 해당 API 작업을 한 번 성공시킨다.
5. 모든 consumer를 새 token으로 바꾼 뒤 이전 token 사용이 없음을 확인한다.
6. Sentry UI에서 이전 token을 revoke한다.
7. 운영 기록에는 값이 아니라 회전 일시, 소유자, scope, 검증 결과만 남긴다.

노출이 의심되면 정상 주기를 기다리지 않고 새 token 발급 → consumer 교체 → 기존
token revoke 순서로 즉시 회전한다. Cloudflare service token도 동일한 원칙으로 별도
회전한다.

## Event 데이터 최소화

SDK를 처음 연결할 때와 월 1회, 그리고 SDK/config 변경 후 실제 event 표본을 Sentry
UI에서 확인한다.

- `request.headers`: `Authorization`, API key, 내부 proxy header가 없어야 한다.
- `cookies`: session, refresh token, CSRF 값 등은 원문을 보내지 않는다.
- URL/query: 검색어, token, 이메일, 좌표 등 민감한 query를 제거한다.
- request body: 비밀번호, 결제, 메시지 본문, 업로드 내용은 allowlist 방식으로 제한한다.
- breadcrumbs: console/network breadcrumb에 payload나 credential이 없는지 확인한다.
- user context: 내부 식별에 필요한 최소 ID만 보내고 이메일/IP/이름은 필요성을 따진다.
- location context: 정밀 좌표, 주소, 이동 기록은 기본 수집하지 않는다.

각 SDK의 `beforeSend` 또는 event processor에서 서버로 전송하기 **전에** 제거한다.
필드명이 계속 늘 수 있는 headers/body는 일부 denylist보다 허용 필드만 남기는 방식을
우선한다. Error Monitoring 목적이므로 trace sample rate는 기본 0으로 유지하고 Replay,
Profiling, Crons, Uptime, AI 기능을 별도 승인 없이 켜지 않는다.

민감 데이터가 이미 저장되었다면 다음 기준으로 결정한다.

- 단순 저위험 debug 문맥이고 노출 범위가 제한적이면 유입을 먼저 막고 7/14일 retention
  cleanup을 기다릴 수 있다.
- credential, 인증 cookie, 개인 민감정보, 정밀 위치처럼 악용 가능하거나 삭제 의무가
  있는 값이면 token/password를 먼저 폐기하고 해당 issue/event/project의 즉시 삭제를
  검토한다. 삭제 전에 필요한 보안 증적만 별도 접근통제 위치에 남긴다.
- 삭제를 위해 Docker volume이나 DB row를 직접 지우지 않는다. Sentry UI/API의 지원된
  삭제 경로를 사용하고 결과를 확인한다.

backup에는 동일한 민감 데이터가 남을 수 있다. 즉시 삭제 사건에서는 영향받은 backup의
보존 필요성과 폐기도 함께 판단한다.
