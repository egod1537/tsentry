# 운영

tsentry는 production observability platform이 아니라 개발·디버깅 보조 도구다. Event
수집보다 Trasolve, troute, tcache의 가용성과 Mac mini의 disk/RAM 여유를 항상 먼저
보호한다.

## 서비스 의존성 원칙

Sentry는 애플리케이션의 **optional side effect**다.

- Sentry가 내려가도 application request와 핵심 기능은 100% 동작해야 한다.
- SDK 전송 실패 때문에 API request를 실패시키거나 사용자 응답을 기다리게 하지 않는다.
- Trasolve/troute/tcache healthcheck에 Sentry health를 필수 조건으로 넣지 않는다.
- Sentry container, network, volume을 application Compose project와 공유하지 않는다.
- Sentry 장애가 앱 장애로 전파되면 개별 container 문제가 아니라 설계 결함으로 처리한다.

SDK는 비동기 전송, 짧은 timeout, 제한된 queue를 사용한다. process 종료 시 flush가
필요하더라도 request path에서는 기다리지 않는다.

## 시작과 종료

```bash
./scripts/start.sh
./scripts/status.sh
./scripts/stop.sh
```

`start.sh`는 Compose stack을 시작하고 `/_health/`가 응답할 때까지 기다린다. Compose
자체는 `up -d --wait`로 모든 healthcheck를 기다린다. `stop.sh`는 `docker compose down`
만 사용하며 `-v`를 사용하지 않는다. volume 삭제는 자동화하지 않는다.

## 정기 점검

자동화가 아직 필요하지 않은 단계에서는 cron이나 별도 supervisor를 추가하지 않는다.
최초 한 달은 주 1회, 안정화 후에는 월 1회와 장애 발생 시 아래를 확인하고 결과를
운영 기록에 붙인다.

```bash
# Compose 상태와 unhealthy/restarting 여부
./scripts/status.sh

# 필요하면 upstream에서 원본 명령을 실행
cd vendor/self-hosted
docker compose --env-file .env --env-file .env.custom ps

# 순간 container CPU/RAM; 2~3회 비교하면 일시 spike를 구분하기 쉽다
docker stats --no-stream

# Docker 전체/상세 disk 사용량
docker system df
docker system df -v

# Sentry container에 실제 연결된 named volume
for id in $(docker compose --env-file .env --env-file .env.custom ps -aq); do
  docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{println .Name}}{{end}}{{end}}' "$id"
done | sort -u

# 주요 service와 전체 stack의 최근 로그
docker compose --env-file .env --env-file .env.custom logs --since=30m web relay nginx
docker compose --env-file .env --env-file .env.custom logs --since=30m
```

해석 기준:

- `Up`이 아니거나 `unhealthy`/`restarting`이면 restart를 반복하기 전에 해당 service의
  최근 log, Docker RAM, host disk를 확인한다.
- idle인데 특정 container CPU가 계속 높거나 RAM이 매 점검마다 증가하면 유입량과
  consumer backlog를 확인한다.
- `docker system df -v`의 reclaimable 표시는 삭제 승인이 아니다. 이 daemon을 공유하는
  다른 서비스 image/cache일 수 있다.
- volume 이름만으로 삭제 대상을 판단하지 않는다. container mount와 backup 존재를 함께
  확인한다.
- log에서 secret/event payload를 issue나 채팅에 그대로 복사하지 않는다.

## 최초 리소스 관찰과 기능 변경

배포가 안정된 뒤 다른 workload를 평소처럼 실행한 상태에서 다음 두 기록을 만든다.

```bash
./scripts/observe.sh idle
# 최소 10분 idle 대기 후 자동 snapshot

# 별도 test project/SDK에서 error event를 몇 건 전송한 뒤
./scripts/observe.sh post-events
```

결과는 `runtime/observations/`에 저장된다. 각 기록에는 aggregate RAM/CPU, disk,
container 수와 가장 메모리를 많이 쓰는 container가 포함된다. 목적은 정밀 benchmark가
아니라 기존 서비스와 공존할 headroom이 있는지 확인하는 것이다.

| 측정 | Idle | Test events 후 |
|---|---:|---:|
| RAM | 배포 차단으로 미측정 | 배포 차단으로 미측정 |
| CPU | 배포 차단으로 미측정 | 배포 차단으로 미측정 |
| Host/Docker disk | 배포 차단으로 미측정 | 배포 차단으로 미측정 |
| Container 수 | 배포 차단으로 미측정 | 배포 차단으로 미측정 |
| 최대 RAM container | 배포 차단으로 미측정 | 배포 차단으로 미측정 |

실제 배포 후 observation 파일의 요약값으로 이 표를 갱신한다. 현재 차단 사유와 배포 전
측정값은 [deployment-record.md](deployment-record.md)에 기록했다.

기본 profile은 항상 `errors-only`다. Session Replay, Profiling, Uptime, Crons, 대량
tracing, AI 기능을 이유 없이 켜지 않는다. 새 기능이 꼭 필요하면 한 번에 하나만 켜고,
변경 전 idle/post-event 기준값과 변경 후 동일 조건의 CPU/RAM/disk/container 수를
비교해 유지 또는 철회를 결정한다.

## Retention

기본 event 보존은 `.env`의 `SENTRY_EVENT_RETENTION_DAYS=14`다. 90일 upstream 기본값을
그대로 사용하지 않는다. 다음 중 하나면 7일로 줄이는 것을 검토한다.

- Sentry volume이 예상보다 빠르게 증가한다.
- Mac mini free disk가 운영자가 정한 안전선 아래로 내려간다.
- 실제 debugging에 14일 이력이 필요하지 않다.

```bash
# .env: SENTRY_EVENT_RETENTION_DAYS=7
./scripts/start.sh
./scripts/status.sh
```

cleanup은 즉시 모든 파일을 반환하지 않을 수 있으므로 daily cleanup과 실제 Docker disk
사용량을 며칠간 관찰한다. 14일 이상으로 늘리기 전에는 ClickHouse, PostgreSQL,
SeaweedFS와 backup archive 증가량을 별도로 검토한다.

## 재부팅과 자동 복구

공식 `26.9.0` Compose의 errors-only 장기 실행 service는 `restart: unless-stopped`다.
현재 OrbStack은 `app.start_at_login=true`다. 따라서 Mac 재부팅 후 해당 사용자 login,
OrbStack Docker daemon 기동, container 자동 재시작 순서로 복구되는 구조다. 별도
launchd supervisor는 추가하지 않는다.

배포 후 `./scripts/recovery-check.sh`를 먼저 통과시키고, 승인된 점검 시간에 Mac을 한 번
재부팅한 뒤 다음을 확인한다.

```bash
./scripts/status.sh
curl --fail http://127.0.0.1:9000/_health/
```

`stop.sh`는 container를 제거하므로 의도적으로 중지한 뒤에는 restart policy가 복구할
대상이 없다. 이 경우 `start.sh`로 다시 생성한다. 사용자 login 전부터 반드시 구동해야
한다는 요구가 생길 때만 launchd를 별도 설계한다.

## Disk와 로그

disk 부족 시 우선순위는 다음과 같다.

1. 유입량과 volume 증가 원인을 확인하고 retention을 14일에서 7일로 낮춘다.
2. 보존이 끝난 event가 cleanup된 뒤 공간 변화를 확인한다.
3. 사용하지 않는 Sentry project, artifact, attachment는 소유자 승인 후 UI/API에서
   정리한다.
4. `docker system df -v`로 **Sentry와 무관한** dangling image/build cache를 식별하고,
   해당 서비스의 build/rollback 영향을 검토한 뒤 별도 승인 절차로 정리한다.

`docker system prune -a --volumes`, wildcard volume 삭제, Compose의 volume 동시 삭제
옵션은 운영 절차에 사용하지 않는다. 이 Docker daemon은 다른 서비스와 공유하므로 전역
정리를 자동화하지 않는다.

## Backup 책임 범위

event 전체의 영구 보존은 목표가 아니다. 반드시 보존할 것은 pinned version, tsentry
운영 설정/문서, 그리고 organization/project를 재구성할 수 있는 최소 인벤토리다.
organization slug, project slug, 담당자, SDK platform, 사용 중인 integration/token의
이름과 scope를 값 없이 운영 기록에 남긴다. 최초 배포 후
[instance-inventory.example.md](instance-inventory.example.md)를
`runtime/instance-inventory.md`로 복사해 사용한다.

`scripts/backup.sh`는 수동 실행 시 stack을 잠시 stop하고 다음을
`backups/<UTC timestamp>/` 아래에 저장한다.

- `.env`, upstream Sentry/Relay/Symbolicator 설정, tsentry 문서와 script
- 존재하는 경우 `runtime/instance-inventory.md`의 비밀값 없는 복구 인벤토리
- 이 Compose project container에 연결된 모든 named Docker volume
- 고정된 핵심 external volume 6개의 존재 여부
- 버전, commit, Docker version manifest와 `SHA256SUMS`

volume은 read-only로 mount해 tar archive를 만들며 원본을 삭제하거나 변경하지 않는다.
실패하면 non-zero로 끝나고, 이전에 실행 중이던 stack은 가능한 경우 다시 시작한다.
archive에는 secret, 사용자 정보, event payload가 포함될 수 있으므로 암호화된 저장소로
옮기고 접근을 제한한다. `backups/`는 Git에서 제외된다.

full-volume backup은 시간과 disk를 많이 쓰므로 자동 cron으로 누적하지 않는다. upgrade
직전이나 복구 가치가 생긴 구성 변경 후 수동으로 만들고, 보존 개수와 외부 암호화 사본은
운영자가 결정한다. org/project metadata까지 보존하려면 PostgreSQL 등 전체 상태가
필요하다. 설정 archive만으로 복구된다고 가정하지 않는다.

복구는 [restore.md](restore.md)의 승인 기반 절차를 따른다. 기존 volume을 덮어쓸 수 있어
자동 restore script는 제공하지 않는다.

## 계정, token, event 데이터

공개 가입은 생성 설정에서 비활성화한다. admin 공유를 최소화하고 개인별 계정과 최소
권한 token을 사용한다. DSN은 수집 식별자이고 admin/auth token은 API 권한이 있는
secret이므로 서로 같은 방식으로 취급하지 않는다. token 회전과 event 표본 점검 절차는
[security.md](security.md)를 따른다.

월 1회 실제 event를 열어 request headers, cookies, URL query, body, breadcrumbs, user,
location context를 표본 검사한다. 민감 데이터는 SDK `beforeSend` 등에서 전송 전에
제거한다. 이미 저장된 데이터는 위험도에 따라 retention cleanup을 기다릴지 지원된 UI/API
경로로 즉시 삭제할지 결정하며 DB/volume을 직접 수정하지 않는다.

## 장애 대응

다음 순서를 바꾸지 않는다.

1. Trasolve, troute, tcache와 Cloudflare edge가 정상인지 먼저 확인한다.
2. Mac mini host disk/RAM과 Docker 할당 RAM을 확인한다.
3. `./scripts/status.sh`로 Sentry container 상태와 순간 자원을 확인한다.
4. `docker compose ... logs --since=30m <service>`로 restart loop인 특정
   consumer/service의 원인을 확인한다.
5. host 자원 보호가 필요하면 `./scripts/stop.sh`로 **tsentry만** 중지한다.
6. application service를 재시작하거나 shared Docker 자원을 prune하지 않는다.

Sentry 중지 후 application이 회복되지 않거나 Sentry 전송 실패가 application error로
나타나면 SDK timeout/queue/health dependency를 수정해야 한다. Sentry를 먼저 억지로
살리는 것으로 사건을 종료하지 않는다.

## 종료와 철거

철거는 자동화하지 않으며 다음 순서와 승인 기록을 따른다.

1. 보존할 issue/export와 운영 인벤토리를 확인하고 필요한 경우 암호화해 저장한다.
2. `./scripts/stop.sh`로 tsentry container만 내린다.
3. `docker volume inspect`와 `docker system df -v`로 관련 volume 이름/크기를 기록한다.
4. backup/보존 요구와 정확한 대상을 재확인한 뒤, 명시적 승인으로만 volume을 삭제한다.
5. shared edge Caddy의 tsentry import/mount와 singleton route를 제거하고 Caddy를 검증한다.
6. Cloudflare Tunnel hostname/DNS와 Access application/policy를 제거한다.
7. Sentry auth token과 Cloudflare service token을 revoke하고 CI secret을 제거한다.
8. 외부 hostname이 더 이상 origin에 도달하지 않는지 확인한 뒤 철거 기록을 남긴다.

Trasolve branch route, application network/volume, 다른 tunnel은 철거 대상에 포함하지
않는다.
