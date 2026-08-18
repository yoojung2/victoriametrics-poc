# 운영 쿼리 가이드 — VM · AKS 부하 기반 실전 쿼리 (개발자용)

> 📚 [← 전체 개요(README)](../README.md) · [Step 1](step1-install.md) · [Step 2](step2-app-metrics.md) · [Step 3](step3-aks-pipeline.md) · **운영 쿼리 가이드**

octocat-supply(prom-client 계측) 앱에 **실제 부하를 흘린 상태**에서, 서비스 운영 시 개발자가 자주 보는 쿼리를 **VM·AKS 양쪽에서 실측 검증**해 정리했습니다.
모든 값은 이 저장소의 파이프라인으로 실제 측정한 결과입니다.

- **VM**: `env="poc"` (systemd 상시 부하) · `http://<VM_PUBIP>:8428`
- **AKS**: `env="poc-aks"` (loadgen Deployment) · `kubectl port-forward … 8428`
- 두 환경은 **같은 vmsingle/VM 저장 구조 + 동일 메트릭 이름**이라 `env` 라벨만으로 구분/비교됩니다.

---

## 0. 개발자가 실제로 보는 4대 신호 (RED + USE)

| 관점 | 신호 | 왜 보는가 |
|------|------|-----------|
| **R**ate | 초당 요청 수(RPS) | 트래픽 규모/급증 감지 |
| **E**rrors | 에러 비율(4xx/5xx) | 장애·배포 회귀 감지 |
| **D**uration | 지연시간 분위수(p50/p95/p99) | 사용자 체감 성능 (SLO) |
| **USE** | 리소스(CPU/메모리/이벤트루프) | 원인 규명·용량 산정 |

---

## 1. Rate — 트래픽 (✅ 실측)

```promql
# 전체 RPS
sum(rate(http_requests_total[1m]))

# 상태코드별 RPS (2xx/4xx 분해)
sum by (status) (rate(http_requests_total[1m]))

# 환경 비교 (VM vs AKS 한 그래프)
sum by (env) (rate(http_requests_total[1m]))
```

| 쿼리 | VM(poc) | AKS(poc-aks) |
|------|---------|--------------|
| `sum(rate(...[1m]))` | 26.05 req/s | 17.7 req/s |
| status=200 | 22.35 | 15.2 |
| status=404 | 3.70 | 2.5 |

> **왜 `rate()`?** `http_requests_total`은 **누적 카운터**라 raw 값은 그래프로 의미가 약합니다. `rate()`가 초당 증가분을 계산합니다.

---

## 2. Errors — 에러율 (✅ 실측)

```promql
# 에러 비율(%) = 4xx+5xx / 전체
100 * sum(rate(http_requests_total{status=~"4..|5.."}[5m]))
    / sum(rate(http_requests_total[5m]))
```

| | VM | AKS |
|---|----|----|
| error_ratio | **12.56 %** | 14.12 % |

> 여기 404가 높은 건 loadgen이 일부러 `/nonexistent`를 때리기 때문입니다. 실서비스라면 이 쿼리가 **배포 직후 회귀·장애의 1차 알람** 기준이 됩니다(예: `> 5%` 경보).

---

## 3. Duration — 지연시간 분위수 (✅ 실측)

```promql
# p95 (초→ms). sum by (le) 필수!
1000*histogram_quantile(0.95, sum by (le)(rate(http_request_duration_seconds_bucket[5m])))

# p50 / p99 는 0.50 / 0.99 로
# 평균(참고): _sum / _count
1000*sum(rate(http_request_duration_seconds_sum[5m]))
    /sum(rate(http_request_duration_seconds_count[5m]))
```

| 분위수 | VM | AKS |
|--------|----|----|
| p50 | 2.50 ms | 2.50 ms |
| p95 | 4.75 ms | 4.75 ms |
| p99 | 4.95 ms | 4.95 ms |
| avg | 0.56 ms | 0.34 ms |

> **왜 평균 대신 분위수?** 평균(0.5ms)은 꼬리 지연을 숨깁니다. 사용자 체감은 **p95/p99**로 봐야 하고, SLO도 보통 분위수로 정의합니다(예: "p95 < 300ms").
> **주의:** `histogram_quantile`은 반드시 `sum by (le)`로 집계해야 하며, 정밀도는 미들웨어의 `buckets` 경계에 좌우됩니다.

---

## 4. USE — 리소스/런타임 (✅ 실측)

```promql
process_resident_memory_bytes / 1024/1024       # RSS(MB)
rate(process_cpu_seconds_total[1m])             # CPU(코어)
nodejs_heap_size_used_bytes / 1024/1024         # V8 heap(MB)
1000*nodejs_eventloop_lag_mean_seconds          # 이벤트루프 지연(ms)
(time() - process_start_time_seconds)/60        # uptime(분)
```

| 지표 | VM | AKS |
|------|----|----|
| RSS | 100.8 MB | 90.8 MB |
| CPU | 0.044 코어 | 0.015 코어 |
| heap used | 20.6 MB | 17.4 MB |
| eventloop lag | 10.3 ms | 10.1 ms |

> **Node.js 특화:** `nodejs_eventloop_lag_*`는 이벤트루프가 막히는지를 보여주는 핵심 신호입니다(동기 블로킹/GC 과다 감지). `collectDefaultMetrics()`가 자동 수집합니다.

---

## 5. MetricsQL 고유 기능 (Prometheus 대비 유의미한 차이, ✅ 실측)

VictoriaMetrics는 **MetricsQL**(PromQL 상위호환)을 씁니다. 아래는 실제로 검증한 차이점입니다.

### 5-1. `rate()` 구간(range) 생략 가능 — PromQL이면 에러
```promql
sum(rate(http_requests_total{env="poc"}))     # ✅ VM에서 success (=131.66)
```
PromQL에서는 `rate()`에 `[range]`가 **필수**라 파싱 에러가 납니다. MetricsQL은 기본 구간을 자동 적용합니다.

### 5-2. 자주 쓰는 편의 함수 (검증)
```promql
topk(3, sum by (status)(rate(http_requests_total[1m])))   # 상위 3개 (200=22.4, 404=3.72)
sum(increase(http_requests_total{env="poc"}[5m]))         # 5분간 총 증가량 (=39,475)
```

> MetricsQL 확장: 구간 생략, `WITH` 템플릿, `keep_metric_names`, `rollup_*`/`range_*` 계열, 더 관대한 파싱. **기존 PromQL은 100% 그대로 동작**하므로 학습비용 없이 상위 기능만 추가로 얻습니다.

---

## 6. VM vs AKS 비교 관점

| 항목 | VM(poc) | AKS(poc-aks) | 메모 |
|------|---------|--------------|------|
| RPS | 26 | 17.7 | 부하기 설정/파드 리소스 차이 |
| p95 | 4.75 ms | 4.75 ms | 동일 앱 → 지연 프로파일 유사 |
| RSS | 100 MB | 91 MB | 컨테이너 cgroup 제한 영향 |
| CPU | 0.044 | 0.015 | 측정 시점 부하 차이 |

한 화면 비교 쿼리:
```promql
sum by (env) (rate(http_requests_total[1m]))
sum by (env) (rate(http_requests_total{status=~"4..|5.."}[5m]))
```

> 같은 메트릭 이름 + `env` 라벨 덕분에, VM/AKS를 **하나의 vmui 대시보드에서 나란히** 볼 수 있습니다.

---

## 7. VictoriaMetrics vs Prometheus — 운영 관점 요약

| 관점 | Prometheus | 본 구성(VictoriaMetrics) |
|------|-----------|--------------------------|
| 수집 | Prometheus 서버가 scrape+저장 | **vmagent**(scrape) + **vmsingle**(저장) 분리 |
| 쿼리 | PromQL | **MetricsQL**(PromQL ⊃) — rate 구간 생략 등 |
| 저장 효율 | 로컬 TSDB | 높은 압축률/메모리 효율, 단일 바이너리 |
| 계측 호환 | `/metrics` + prom-client | **동일** (앱 코드 재사용) |
| 읽기 API | `/api/v1/query` | **동일** → Grafana Prometheus 소스로 연결 |

> 핵심: **계측·쿼리·API 표준(Prometheus 생태계)은 그대로 유지**하고 저장/쿼리 엔진만 교체 → 개발자는 배우던 PromQL·`/metrics`를 그대로 쓰면서 운영 효율만 얻습니다.

---

## 8. 바로 쓰는 알람 기준 예시 (참고)

```promql
# 에러율 5% 초과 (5분)
100*sum(rate(http_requests_total{status=~"5.."}[5m]))/sum(rate(http_requests_total[5m])) > 5

# p95 300ms 초과
1000*histogram_quantile(0.95, sum by (le)(rate(http_request_duration_seconds_bucket[5m]))) > 300

# 이벤트루프 지연 100ms 초과 (Node 블로킹)
1000*nodejs_eventloop_lag_mean_seconds > 100
```

---

## 부록 — 검증 방법 (재현)

```bash
# VM
curl -s "http://<VM_PUBIP>:8428/api/v1/query" \
  --data-urlencode 'query=sum by (status)(rate(http_requests_total{env="poc"}[1m]))'

# AKS (port-forward 후)
kubectl -n vm port-forward svc/vmsingle-victoria-metrics-single-server 8428:8428
curl -s "http://localhost:8428/api/v1/query" \
  --data-urlencode 'query=sum by (status)(rate(http_requests_total{env="poc-aks"}[1m]))'
```

> 측정 시점의 부하 상황에 따라 절대값은 달라질 수 있습니다. 쿼리 구조와 상대적 해석이 핵심입니다.
