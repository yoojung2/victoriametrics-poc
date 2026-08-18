#!/usr/bin/env bash
# Step 2 — octocat API에 부하(트래픽) 생성기
# 사용: ./scripts/loadgen.sh [BASE_URL] [DURATION_SEC]
#   ./scripts/loadgen.sh http://localhost:3000 60
set -euo pipefail

BASE="${1:-http://localhost:3000}"
DURATION="${2:-60}"

echo ">> 부하 생성 시작: $BASE (${DURATION}s)"
END=$(( $(date +%s) + DURATION ))

# 정상 요청 + 일부 404를 섞어 다양한 status 라벨 생성
ENDPOINTS=(/api/products /api/branches /api/suppliers /api/orders /api/headquarters / /nonexistent)

req=0
while [ "$(date +%s)" -lt "$END" ]; do
  for ep in "${ENDPOINTS[@]}"; do
    curl -s -o /dev/null "${BASE}${ep}" || true
    req=$((req+1))
  done
  sleep 0.2
done
echo ">> 완료: 총 ${req} 요청 전송"
echo ">> 확인:  curl -s ${BASE}/metrics | grep http_requests_total"
