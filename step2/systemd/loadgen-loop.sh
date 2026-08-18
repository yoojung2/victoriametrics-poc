#!/usr/bin/env bash
# VM 상시 부하 생성기 (systemd에서 무한 실행, Restart=always로 24시간+ 유지)
set -u
BASE="${BASE:-http://localhost:3000}"
EPS="/api/products /api/branches /api/suppliers /api/orders /api/headquarters / /nonexistent"
while true; do
  for ep in $EPS; do
    curl -s -o /dev/null "${BASE}${ep}" || true
  done
  sleep 0.2
done
