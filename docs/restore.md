# Backup 복구 절차

복구는 자동화하지 않는다. volume archive를 푸는 작업은 기존 데이터를 덮어쓸 수 있으므로
명시적 승인과 maintenance window에서만 수행한다. 가능하면 먼저 별도 Docker 환경 또는
격리된 Mac에서 복구를 검증한다.

## 복구 전에 결정할 것

1. 복구 목적과 승인자를 기록한다.
2. backup의 `manifest.txt`에서 정확한 Sentry tag, upstream commit, 생성 시각을 확인한다.
3. backup directory에서 `shasum -a 256 -c SHA256SUMS`를 실행해 손상을 확인한다.
4. `tar -tzf configuration.tar.gz`로 내용만 확인한다. 현재 repo 위에 바로 풀지 않는다.
5. 필요한 disk가 원본 volume 합계와 image/migration 여유를 포함해 충분한지 확인한다.
6. 원본 stack과 Trasolve 계열 서비스는 건드리지 않고, 복구 대상 Docker context와
   Compose project가 정확한지 두 번 확인한다.

## 권장 복구 순서

1. `configuration.tar.gz`를 임시 directory에 풀고 `.env`, version, canonical URL을
   검토한다. secret이므로 mode와 접근 권한을 유지한다.
2. 공식 repository에서 `manifest.txt`의 정확한 release tag를 checkout한다. 최신 tag로
   대체하지 않는다.
3. 격리된 대상에서 공식 installer를 실행해 image와 빈 target volume을 준비한 뒤 stack을
   완전히 내린다.
4. `volume-names.txt`와 `volumes/*.tar.gz`가 일대일로 대응하는지 확인한다. PostgreSQL만
   골라 복구하거나 서로 다른 시각의 archive를 섞지 않는다.
5. 각 **빈 target volume**에 대응 archive를 read-only source로 연결한 일회성 helper로
   복구한다. 기존 volume을 재사용해야 한다면 사전 snapshot과 별도 승인이 필요하며,
   자동 삭제·초기화 명령은 사용하지 않는다.
6. 모든 volume을 같은 backup set으로 복구한 뒤 exact pinned tag로 stack을 시작한다.
7. `./scripts/status.sh`, local health, 로그인, organization/project 목록, test error 수집을
   순서대로 확인한다.
8. 검증이 끝나기 전 DNS/Caddy route를 복구 instance로 전환하지 않는다.

organization, project, 사용자, token metadata는 단순 config file이 아니라 PostgreSQL 등
persistent state에 들어간다. 따라서 `configuration.tar.gz`만으로는 이를 복구할 수 없고,
cold backup의 전체 named-volume set이 필요하다. 반대로 event 전체가 필요 없는 단순 재구축은
운영 인벤토리를 바탕으로 organization/project를 새로 만들고 새 DSN/token을 발급하는 편이
더 안전할 수 있다.

복구 실패 시 반복 migration이나 downgrade를 시도하지 않는다. 복구 stack을 멈추고 log와
archive를 보존한 뒤 원본 환경을 그대로 유지한다. volume 삭제는 복구 성공과 보존기간
확인 후 별도 승인으로만 수행한다.
