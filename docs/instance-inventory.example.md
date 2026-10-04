# tsentry instance inventory

이 파일을 `runtime/instance-inventory.md`로 복사해 실제 값을 기록한다. password, DSN,
token, secret 값은 기록하지 않는다.

- 마지막 검토 시각:
- 검토자/운영 책임자:
- Sentry self-hosted version:
- canonical URL:
- retention days:
- Compose profile:

## Organization / project

| Organization slug | Project slug | SDK/platform | 담당자 | 재구성 메모 |
|---|---|---|---|---|
| | | | | |

## Credential inventory

| 이름 | 종류 | 소유자 | 최소 scope | secret 저장 위치 이름 | 마지막 회전일 |
|---|---|---|---|---|---|
| | Sentry internal integration / Cloudflare service token | | | | |

값 자체, password manager item의 secret, DSN 전체 문자열은 적지 않는다.

## Edge와 복구

- Cloudflare Access application/policy 이름:
- Tunnel 이름/UUID:
- Caddy route source:
- 최근 성공 backup 시각/경로 식별자:
- 최근 checksum 검증일:
- 최근 격리 restore drill 결과:

## Resource baseline

- Idle 관찰 파일:
- Post-event 관찰 파일:
- 정상 container 수:
- 정상 idle RAM/CPU 범위:
- disk 안전선:
- 가장 큰 volume/container:
