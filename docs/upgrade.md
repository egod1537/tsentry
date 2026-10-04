# 업그레이드와 rollback 판단

업그레이드는 자동 latest 추적이 아니라 검토된 목표 stable release로만 수행한다.
maintenance window 전에는 현재 서비스와 volume을 변경하지 않는다.

## 준비

1. `./scripts/status.sh`와 `git -C vendor/self-hosted describe --tags --exact-match`로 현재
   version/상태를 기록한다.
2. 공식 [release 목록](https://github.com/getsentry/self-hosted/releases)에서 목표 stable
   tag를 정한다.
3. 현재부터 목표까지 **모든** release notes, hard-stop release, breaking config change,
   최소 Docker/Compose 요구사항을 읽는다. 여러 monthly release를 건너뛰면 공식 upgrade
   guidance가 직접 점프를 허용하는지 먼저 확인하고 필요한 중간 tag를 순서대로 적용한다.
4. host/Docker disk와 RAM 여유, 최근 backup 복구 가능성을 확인한다.
5. test event를 보낼 Trasolve test environment/project와 점검 담당자를 정한다.

release notes 검토 후 목표 tag를 명시한다.

```bash
./scripts/update.sh <target-release> --ack-release-notes
```

예:

```bash
./scripts/update.sh 26.10.0 --ack-release-notes
```

## Script가 수행하는 작업

1. 현재 checkout과 공식 origin을 검증한다.
2. 목표 tag가 공식 remote에 실제 존재하는지 확인한다.
3. stack을 멈추고 구성, 운영 문서, Docker volume 전체를 timestamped cold backup한다.
4. 정확한 tag를 fetch/checkout한다.
5. `.env`, `.env.example`, README의 pin을 변경한다.
6. 목표 tag의 공식 `install.sh`를 실행한다.
7. canonical URL과 공개 가입 비활성화 정책을 다시 적용한다.
8. 자동 시작하지 않고 검토를 위해 정지 상태로 남긴다.

설치가 성공하면 `git diff`로 pin과 문서 변경을 검토하고 이 repo에 별도 commit한다.
그 다음:

```bash
./scripts/start.sh
./scripts/status.sh
./scripts/check-edge-readiness.sh
```

local health, 외부 로그인, organization/project 화면, HTTPS DSN을 확인하고 Trasolve test
error 한 건을 보낸다. issue가 생성되고 application request가 Sentry 응답을 기다리지
않는지 확인한 뒤 maintenance를 종료한다.

## 실패와 rollback

DB migration이 실행된 뒤에는 이전 image tag로 checkout하는 것만으로 안전하게
downgrade되지 않는다. 실패 시 반복 installer 실행, volume 일부 삭제, 이전/새 image
혼용을 하지 않는다.

1. tsentry stack만 중지하고 installer/compose log, 실패 시각, 이전/목표 tag, backup
   directory를 보존한다.
2. application과 edge가 정상인지 확인한다. application은 Sentry 없이 계속 동작해야 한다.
3. 공식 release note/issue에서 forward-fix가 안전한지 판단한다.
4. migration 전 문제라면 checkout/config 오류를 바로잡고 같은 target을 재시도할 수 있다.
5. migration 후 문제라면 이전 cold backup의 **전체 volume set**을 격리 환경에 복구해
   검증한 후 전환한다. [restore.md](restore.md)를 따르며 일부 DB만 되돌리지 않는다.
6. 복구 검증 전 DNS/Caddy route나 기존 volume을 변경하지 않는다.

rollback은 “tag만 이전으로 변경”이 아니라 application version과 persistent state를 같은
시점으로 되돌리는 작업이다. downtime보다 event 이력의 가치가 낮다면, 이전 backup
복구 대신 exact stable tag로 빈 instance를 재구축하고 organization/project와 새 DSN을
재생성하는 선택도 검토한다.

현재 pin `26.9.0` release에는 PostgreSQL/glibc 재색인과 관련해 기존 설치의 duplicate
row가 upgrade를 막을 수 있다는 경고가 있다. 신규 설치에는 해당 migration 이력이 없지만,
기존 instance를 이 버전으로 올리는 경우 공식 release note를 반드시 따른다.
