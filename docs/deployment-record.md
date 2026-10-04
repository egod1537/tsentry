# Mac mini deployment record

측정 시각: 2026-10-04 22:15 KST (`20261004T131545Z`)

## 배포 전 측정

| 항목 | 측정값 |
|---|---:|
| CPU architecture | Apple Silicon `arm64` / Docker `aarch64` |
| Host CPU | 10 logical CPUs |
| Host RAM | 16.0 GiB |
| OrbStack Docker 할당 | 10 CPUs / 8,004 MiB |
| Host 가용 disk | 23 GiB |
| Docker Engine | 29.4.0 |
| Docker Compose | 5.1.2 |
| 현재 실행 container | 46 |
| non-Sentry container RAM snapshot | 2,506 MiB |
| Sentry에 남는 추정 Docker RAM | 5,498 MiB |
| Docker images / build cache | 17.13 GB / 8.631 GB |

현재 큰 memory consumer는 `open-webui` 약 594 MiB, `shlink` 약 445 MiB,
`jsb1-impl-backend-1` 약 142 MiB, `uptime-kuma` 약 118 MiB,
`searxng` 약 109 MiB 순이었다. 이는 단일 snapshot이며 benchmark가 아니다. 전체 원본은
Git에서 제외된 `runtime/preflight-20261004T131545Z.log`에 있다.

## Startup/restart 확인

- OrbStack 2.2.3의 `app.start_at_login=true` 확인
- 공식 `26.9.0` Compose 기본 restart policy: `unless-stopped`
- errors-only rendered network: Compose 전용 `default` 하나
- OrbStack 전역 `docker.expose_ports_to_lan=true`이므로 Sentry의
  `SENTRY_BIND=127.0.0.1:9000`을 변경하지 않는 것이 특히 중요함
- 기존 OrbStack 전역 설정은 다른 서비스에 영향을 줄 수 있어 변경하지 않음

## 결정

**배포 중단.** 다음 두 hard failure가 해소되지 않아 공식 installer를 실행하지 않았다.

1. 현재 PATH의 Bash는 3.2.57이며 upstream 최소 버전은 4.4.0이다.
2. 기존 container 사용량을 제외한 Docker RAM 여유가 5,498 MiB로, 공존 보호 gate인
   7,000 MB보다 작다.

가용 disk 23 GiB는 공식 권장 floor 20 GB는 넘지만 image pull, event data, cold backup을
동시에 보관하기에는 여유가 작아 40 GiB 미만 경고 상태다. 기존 서비스에 영향을 주는
OrbStack memory 변경이나 전역 Docker prune은 자동 수행하지 않았다.

해소 후 `scripts/preflight.sh`를 다시 실행해 모든 `FAIL`이 사라진 기록을 남기고 배포를
재개한다. 배포 전이므로 idle/test-event Sentry resource 수치는 아직 없다.

가능한 해소 방향은 현재 workload 축소/이전 또는 host 여유를 확인한 뒤 OrbStack RAM
상한 조정이다. 16 GiB host에서 Docker에 무리하게 RAM을 배정하면 macOS와 다른 native
process가 압박받을 수 있으므로 자동 변경하지 않는다. disk 정리도 다른 project의 build
cache와 rollback image에 영향을 줄 수 있어 소유자 검토 없이 실행하지 않는다.
