# Step 4 — Grafana 대시보드 연동 (✅ 실측 검증)

> 📚 [← 전체 개요(README)](../README.md) · [Step 3: AKS](step3-aks-pipeline.md) · [쿼리 가이드](query-guide.md) · **Step 4: Grafana**

VictoriaMetrics(vmsingle)에 **Grafana를 연결**해 octocat-supply의 RED 대시보드를 실제로 띄우고,
Grafana API로 datasource health와 각 패널 쿼리가 **실데이터를 반환하는 것까지 검증**했습니다.

## 전체 구조

```
[Grafana] --프록시 쿼리(Prometheus API)--> [vmsingle :8428] <-- vmagent가 채운 octocat 메트릭
   ↑ datasource(provisioning) + RED 대시보드(provisioning) 자동 설정
```

> **핵심:** vmsingle은 Prometheus HTTP API 호환이라 Grafana에서 **`type: prometheus` 데이터소스로 그대로 연결**됩니다. 별도 플러그인 불필요.

## 구성 요소

| 리소스 | 파일 | 역할 |
|--------|------|------|
| datasource provisioning | [step4/k8s/01-grafana-provisioning.yaml](../step4/k8s/01-grafana-provisioning.yaml) | vmsingle을 `type: prometheus`, `uid: victoriametrics`로 연결 |
| dashboard provider | 위 파일 | `/var/lib/grafana/dashboards` 파일 자동 로드 |
| RED 대시보드 | [step4/dashboards/octocat-red.json](../step4/dashboards/octocat-red.json) | RPS/에러율/지연분위수/메모리/이벤트루프 6패널 |
| Grafana | [step4/k8s/02-grafana.yaml](../step4/k8s/02-grafana.yaml) | Deployment + Service |

---

## 1. 배포

```bash
# 대시보드 JSON을 ConfigMap으로
kubectl -n vm create configmap grafana-dashboards \
  --from-file=octocat-red.json=step4/dashboards/octocat-red.json \
  --dry-run=client -o yaml | kubectl apply -f -

# provisioning(datasource+provider) + grafana 배포
kubectl apply -f step4/k8s/01-grafana-provisioning.yaml
kubectl apply -f step4/k8s/02-grafana.yaml
kubectl -n vm rollout status deploy/grafana
```

## 2. 접속

```bash
kubectl -n vm port-forward svc/grafana 3001:3000
# http://localhost:3001  (admin / admin)
```

---

## 3. 검증 결과 (✅ 실측)

### 3-1. datasource health — Grafana → vmsingle 연결
```bash
$ curl -s "http://admin:admin@localhost:3001/api/datasources/uid/victoriametrics/health"
{"status":"OK","message":"Successfully queried the Prometheus API.",
 "details":{"application":"Prometheus", ...}}
```
→ **OK** (Grafana가 vmsingle을 Prometheus로 정상 인식)

### 3-2. 대시보드 provisioning 로드
```bash
$ curl -s "http://admin:admin@localhost:3001/api/search?query=octocat"
'octocat-supply — RED Dashboard' uid=afvkdtg8uvpc0f type=dash-db
```
→ 자동 로드됨

### 3-3. 각 패널 쿼리 실데이터 (Grafana 프록시 경유, env=poc-aks)

| 패널 | 쿼리 | 실측값 |
|------|------|--------|
| Total RPS | `sum(rate(http_requests_total[1m]))` | **17.7 req/s** |
| RPS by status | `sum by (status)(rate(...))` | 200→15.2 / 404→2.5 |
| Latency p50 | `histogram_quantile(0.50, …)` | 2.50 ms |
| Latency p95 | `histogram_quantile(0.95, …)` | 4.75 ms |
| Latency p99 | `histogram_quantile(0.99, …)` | 4.95 ms |
| Memory RSS | `process_resident_memory_bytes/1024/1024` | 91.1 MB |
| Event loop lag | `1000*nodejs_eventloop_lag_mean_seconds` | 10.16 ms |
| 변수 `$env` | `label_values(http_requests_total, env)` | `["poc-aks"]` |

> 모든 값은 Grafana의 **datasource 프록시 API**(`/api/datasources/proxy/uid/victoriametrics/...`)를 통해 조회 — 즉 Grafana UI 패널이 그리는 것과 동일 경로로 검증했습니다.

---

## 4. 대시보드 구성 (RED + 리소스)

| 패널 | 타입 | 설명 |
|------|------|------|
| Request Rate by status | timeseries | 2xx/4xx RPS |
| Error Ratio (%) | stat | 5% 초과 시 빨강 임계 |
| Total RPS | stat | 현재 처리량 |
| Latency p50/p95/p99 | timeseries | 지연 분위수(ms) |
| Process Memory (RSS) | timeseries | 앱 메모리 |
| Event Loop Lag | timeseries | Node.js 블로킹 신호 |

- **템플릿 변수 `$env`** 로 VM(`poc`) / AKS(`poc-aks`) 전환 가능 (같은 대시보드 재사용)

---

## 5. Prometheus 대비 포인트

| | Prometheus 스택 | 본 구성 |
|---|---|---|
| Grafana 데이터소스 타입 | Prometheus | **동일 (Prometheus)** — vmsingle이 API 호환 |
| 쿼리 | PromQL | MetricsQL(호환) — 대시보드 JSON 그대로 |
| 마이그레이션 | - | 기존 Grafana 대시보드 **수정 없이 재사용** 가능 |

> 즉 Prometheus용으로 만든 Grafana 대시보드를 **데이터소스 URL만 vmsingle로 바꾸면** 그대로 동작합니다.

---

## 6. 운영/정리

```bash
# 대시보드 수정 시 ConfigMap 갱신 후 롤아웃
kubectl -n vm create configmap grafana-dashboards \
  --from-file=octocat-red.json=step4/dashboards/octocat-red.json \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n vm rollout restart deploy/grafana

# 정리
kubectl -n vm delete -f step4/k8s/
kubectl -n vm delete configmap grafana-dashboards
```

## 7. 파일

```
step4/
├── k8s/
│   ├── 01-grafana-provisioning.yaml   # datasource + dashboard provider
│   └── 02-grafana.yaml                # Grafana Deployment + Service
└── dashboards/
    └── octocat-red.json               # RED + 리소스 6패널 대시보드
```
