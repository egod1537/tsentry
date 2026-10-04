# 배포

## 전제 조건

- macOS가 설치된 Mac mini
- OrbStack 또는 Docker Desktop과 Docker Compose v2
- Git, curl, Bash 4.4 이상 (macOS 기본 Bash 3.2가 아니라 Homebrew Bash 등)
- Docker에 할당된 최소 2 CPU / 약 7 GB RAM (`errors-only` 기준)
- container image 및 GitHub에 접근 가능한 네트워크
- 충분한 Docker disk 공간. 초기 image와 데이터에 수십 GB 여유를 권장한다.

Trasolve 배포와는 repository, Compose project, container, volume을 공유하지 않는다.
Upstream 기본 `COMPOSE_PROJECT_NAME=sentry-self-hosted`와 전용 named volume을 그대로
사용한다. 다른 self-hosted Sentry가 이미 같은 Docker daemon에 있다면 이름이
충돌하므로 함께 설치하지 않는다.

## 최초 설치

```bash
git clone <tsentry repository URL> tsentry
cd tsentry
cp .env.example .env
chmod 600 .env
./scripts/preflight.sh
./scripts/bootstrap.sh
./scripts/start.sh
```

`preflight.sh`가 하나라도 `FAIL`을 출력하면 설치를 진행하지 않는다. 공식 최소치뿐
아니라 현재 실행 중인 non-Sentry container를 제외한 Docker RAM 여유가 7,000 MB
이상인지 확인한다. 이는 Trasolve/troute/tcache 등 기존 workload의 메모리를 Sentry가
잠식하지 않도록 하기 위한 이 레포의 보수적인 추가 gate다. 결과는 `runtime/`에
기록되며 Git에는 포함되지 않는다.

`.env`의 필수 정책값은 다음과 같다.

| 변수 | 기본값 | 의미 |
|---|---|---|
| `SENTRY_SELF_HOSTED_VERSION` | `.env.example` 참조 | 공식 release tag pin |
| `SENTRY_BIND` | `127.0.0.1:9000` | host loopback에만 publish |
| `SENTRY_EVENT_RETENTION_DAYS` | `14` | event 보존 기간 |
| `COMPOSE_PROFILES` | `errors-only` | Error Monitoring 전용 profile |

bootstrap은 origin URL과 원격 tag 존재 여부를 확인하고 detached HEAD로 정확한 tag를
checkout한다. admin 생성을 건너뛰고 upstream issue reporting도 비활성화한다.
설치 후 `start.sh`는 공식 권장 방식인 `docker compose up -d --wait`를 실행하고,
container 상태와 `http://127.0.0.1:9000/_health/` 응답을 확인한다.

## 관리자와 접속

```bash
cd vendor/self-hosted
./sentry-admin.sh createuser --superuser
```

Mac mini 로컬 브라우저는 `http://127.0.0.1:9000`을 사용한다. 개발자 PC에서는
예를 들어 `ssh -L 9000:127.0.0.1:9000 <mac-mini>` tunnel을 만든 뒤 같은 주소로
접속할 수 있다. 장기 공유가 필요하면 TLS와 인증/접근제어를 갖춘 reverse proxy를
별도 설계한다. `SENTRY_BIND=0.0.0.0:9000`으로 공인 인터넷에 직접 공개하지 않는다.

Sentry UI에서 조직과 project를 만든 후 발급되는 DSN을 각 서비스의 secret manager
또는 로컬 비공개 환경변수에 설정한다. 이 연결 작업과 DSN은 `tsentry` Git 이력에
포함하지 않는다.

관리자 생성 후 조직만 먼저 만들 수 있으며 project 생성은 연기해도 된다.
`bootstrap.sh`가 생성 설정에 `auth.allow-registration: false`를 적용하므로 공개 가입은
비활성 상태다. 비로그인 창에서도 이를 확인하고, 비밀번호나 admin credential을 shell
script에 넣지 않는다.

## 격리 확인

Upstream Compose는 별도 `sentry-self-hosted_default` network와 `sentry-*` named
volume을 사용한다. 기존 서비스 network를 override로 연결하지 않는다. 설치 후:

```bash
./scripts/recovery-check.sh
```

이 명령은 Sentry network에 다른 Compose project container가 붙어 있지 않은지와
container restart 정책을 읽기 전용으로 확인한다. Cloudflare/Caddy 연결은 이 배포
범위에 포함하지 않으며 `127.0.0.1:9000` bind를 유지한다.

network와 volume 격리는 application 장애 전파를 줄이지만 Docker daemon과 host RAM,
disk는 기존 서비스와 공유한다. 따라서 OOM/disk-full/daemon 장애까지 완전히 분리하는
것은 불가능하며 preflight의 공존 headroom gate를 통과해야 한다. 강한 failure-domain
격리가 필요하면 Sentry를 별도 host 또는 별도 VM/runtime으로 옮긴다. Sentry 때문에
Trasolve/troute/tcache/Cloudflare edge의 network나 container를 재시작하는 운영 명령은
사용하지 않는다.
