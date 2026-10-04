# tsentry

`tsentry`는 Trasolve, troute, tcache 등이 함께 사용하는 **Mac mini용 Sentry
Self-Hosted 운영 레포**다. Sentry 소스를 포크하지 않고 공식
[`getsentry/self-hosted`](https://github.com/getsentry/self-hosted)를 지정 release로
clone하여, 이 레포에는 버전 pin·환경 설정·운영 스크립트·문서만 관리한다.

- 현재 pinned Sentry version: `26.9.0`
- 기본 profile: `errors-only` (Error Monitoring 전용)
- 기본 접속 주소: `http://127.0.0.1:9000`
- 외부 인터넷 직접 노출: 금지. SSH tunnel 또는 인증/TLS reverse proxy 사용
- Sentry Cloud: 사용하지 않음
- 현재 Mac mini 배포 상태: **preflight 차단** ([측정 기록](docs/deployment-record.md))
- 외부 hostname 후보: `sentry.mangagaki.net` (**Access/backend 준비 전 비활성**)

## 빠른 설치

필수 조건은 OrbStack 또는 Docker Desktop(Compose v2 포함), Git, curl, Bash 4.4
이상이다. 공식
self-hosted installer가 Bash 4.4 이상을 요구하므로 macOS 기본 Bash 3.2만 있는 경우
먼저 최신 Bash를 PATH 앞에 둔다. Homebrew를 사용한다면:

```bash
brew install bash
export PATH="$(brew --prefix)/bin:$PATH"
bash --version
```

그 다음 Mac mini에서:

```bash
cp .env.example .env
# 필요하면 .env의 로컬 바인딩/보존기간을 검토한다.
./scripts/preflight.sh
./scripts/bootstrap.sh
./scripts/start.sh
```

`preflight.sh`는 host/Docker 자원, 기존 container 사용량과 disk를
`runtime/preflight-*.log`에 기록하며 공존 여유가 부족하면 실패한다. `bootstrap.sh`도
이 검사를 먼저 실행하므로 실패를 우회해 설치하지 않는다. 통과하면 `.env`의
`SENTRY_SELF_HOSTED_VERSION`에 지정된 공식 tag만 `vendor/self-hosted`에 checkout한
뒤 upstream installer를 실행한다.
`errors-only`도 Docker에 최소 2 CPU와 약 7 GB RAM이 필요하다. 실제 다운로드와
초기 migration에는 시간이 걸릴 수 있다.

관리자 계정은 서비스 시작 후 대화형으로 생성한다:

```bash
cd vendor/self-hosted
./sentry-admin.sh createuser --superuser
```

브라우저는 Mac mini에서 `http://127.0.0.1:9000`으로 접속한다. 다른 기기에서
접속하려면 먼저 SSH tunnel 또는 별도 reverse proxy를 구성한다. Trasolve SDK와
DSN 연결은 Sentry project를 만든 뒤 수행하는 **별도 단계**이며, 실제 DSN이나
비밀번호는 이 레포에 커밋하지 않는다.

## 일상 명령

```bash
./scripts/start.sh       # 시작, container 상태와 web health 확인
./scripts/status.sh      # 상태, unhealthy/restarting, disk 사용량 확인
./scripts/stop.sh        # 중지; volume은 보존
./scripts/backup.sh      # 모든 연결 volume의 cold backup 후 다시 시작
./scripts/recovery-check.sh # restart 정책, runtime startup, network 격리 확인
```

`status.sh`는 Compose 상태뿐 아니라 순간 CPU/RAM, 연결된 named volume, Docker/host
disk 사용량도 출력한다. 정기 점검과 장애 대응 기준은 [운영 문서](docs/operations.md)를
따른다.

최초 배포 후 10분 idle 측정과 test event 전송 후 측정은 각각 다음처럼 기록한다.

```bash
./scripts/observe.sh idle
# test event 몇 건을 전송한 다음
./scripts/observe.sh post-events
```

배포 후 실제 organization/project와 token **값이 아닌** 복구 인벤토리는
[instance-inventory.example.md](docs/instance-inventory.example.md)를 복사해 Git에서 제외된
`runtime/instance-inventory.md`에 기록한다.

업데이트는 목표 release와 release-notes 확인을 반드시 명시한다:

```bash
./scripts/update.sh 26.10.0 --ack-release-notes
```

스크립트는 먼저 cold backup을 만들고 새 tag의 공식 installer를 실행한다. 완료 후
서비스는 검토를 위해 정지 상태로 남는다. 자동으로 `latest`, `master`, `nightly`를
선택하지 않는다.

## 책임 경계와 보안

- `vendor/self-hosted/`: bootstrap 시 받은 공식 upstream이며 Git 추적 대상이 아니다.
- `.env`: 로컬 배포 설정이며 Git에서 제외된다. upstream의 `.env.custom`으로 연결된다.
- `config/`: 향후 필요한 최소 override의 문서/템플릿만 둔다.
- `backups/`, `runtime/`: secret과 event data가 있을 수 있어 Git에서 제외된다.
- Performance, Replay, Profiling이 필요한 경우 용량 검토와 별도 변경 작업을 거쳐
  `feature-complete` 전환을 설계한다. 현재 스크립트는 실수로 이를 켜지 못하게 한다.
- Sentry는 애플리케이션의 optional side effect다. Sentry 장애나 전송 실패가
  Trasolve/troute/tcache 요청, healthcheck, 배포를 실패시키면 안 된다.
- bootstrap/update가 생성 설정에 `auth.allow-registration: false`를 적용한다.

상세 절차는 [배포](docs/deployment.md), [운영](docs/operations.md),
[보안](docs/security.md), [복구](docs/restore.md), [외부 접근](docs/external-access.md),
[업그레이드](docs/upgrade.md)를 참고한다.
