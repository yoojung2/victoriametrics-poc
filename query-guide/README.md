# VictoriaMetrics 실전 쿼리 가이드

서비스 운영 시 개발자가 꼭 알아야 할 쿼리와 개념을 정리합니다.
모든 쿼리는 VM(바이너리)과 AKS(Helm) 양쪽에서 실제 검증되었습니다.

---

## 검증 환경

| 환경 | VictoriaMetrics | 앱 | 부하 |
|------|----------------|-----|------|
| **VM** (20.194.29.17:8428) | v1.108.1 바이너리 | octocat-supply :3000 | nohup 24h |
| **AKS** (port-forward :9428) | Helm (Single) | octocat-supply Deployment x2 | loadgen-24h Pod |

---

## 1. 트래픽 분석 (가장 먼저 볼 것)

### 1-1. 초당 요청 수 (RPS)

```promql
rate(http_requests_total{job="octocat-supply"}[5m])
```

> **왜 중요한가:** 서비스의 현재 부하 수준을 파악하는 가장 기본적인 지표.
> 배포 전후, 트래픽 스파이크, 장애 시점을 즉시 파악할 수 있다.

검증 결과:
```
VM:  /api/products = 0.9333 req/s (경로당 약 1 req/s)
AKS: /api/products = 0.9800 req/s
```

### 1-2. 경로별 RPS (어디에 트래픽이 집중되나)

```promql
sum by (path) (rate(http_requests_total{job="octocat-supply"}[5m]))
```

> **왜 중요한가:** 특정 API에 트래픽이 몰리는지, 예상치 못한 경로로 요청이 오는지 파악.
> 불필요한 호출 패턴이나 크롤러/봇 트래픽도 발견할 수 있다.

검증 결과:
```
VM:  7개 경로 각각 ~0.93 req/s, /metrics = 0.10 req/s
AKS: /api/deliveries = 1.68 req/s (loadgen 타이밍 차이)
```

### 1-3. HTTP 상태 코드별 분포

```promql
sum by (status) (rate(http_requests_total{job="octocat-supply"}[5m]))
```

> **왜 중요한가:** 200 외에 4xx/5xx 비율이 갑자기 올라가면 장애 징후.
> Grafana 대시보드에서 stacked bar로 시각화하면 직관적.

---

## 2. 에러율 & 가용성 (SLO 핵심)

### 2-1. 5xx 에러율

```promql
sum(rate(http_requests_total{job="octocat-supply", status=~"5.."}[5m]))
/
sum(rate(http_requests_total{job="octocat-supply"}[5m]))
```

> **왜 중요한가:** SLO(Service Level Objective)의 핵심 지표.
> "99.9% 가용성" = 에러율 0.1% 미만 유지.
> 알림 룰: `> 0.01` (1% 초과) 시 경고, `> 0.05` (5%) 시 긴급.

검증 결과:
```
VM:  no 5xx (에러 없음 ✅)
AKS: no 5xx (에러 없음 ✅)
```

### 2-2. 경로별 에러율 (어디서 에러가 나는지)

```promql
sum by (path) (rate(http_requests_total{job="octocat-supply", status=~"5.."}[5m]))
/
sum by (path) (rate(http_requests_total{job="octocat-supply"}[5m]))
```

> 전체 에러율이 낮아도 특정 경로에서만 에러가 집중될 수 있다.

---

## 3. 응답 시간 (Latency) - 사용자 경험의 핵심

### 3-1. P95 응답 시간

```promql
histogram_quantile(0.95,
  sum by (le) (rate(http_request_duration_seconds_bucket{job="octocat-supply"}[5m]))
)
```

> **왜 중요한가:** 평균보다 P95/P99가 실제 사용자 경험을 반영한다.
> "평균 10ms인데 P95가 500ms" = 20명 중 1명은 느린 응답을 받는다.

검증 결과:
```
VM:  P95 = 9.50 ms ✅
```

### 3-2. 평균 응답 시간

```promql
rate(http_request_duration_seconds_sum{job="octocat-supply"}[5m])
/
rate(http_request_duration_seconds_count{job="octocat-supply"}[5m])
```

### 3-3. 경로별 P95 (느린 API 찾기)

```promql
histogram_quantile(0.95,
  sum by (path, le) (rate(http_request_duration_seconds_bucket{job="octocat-supply"}[5m]))
)
```

> 전체 P95는 정상이지만 특정 API가 느릴 수 있다. DB 쿼리 최적화 대상 선정에 유용.

---

## 4. Node.js 런타임 모니터링

### 4-1. 프로세스 메모리 (RSS)

```promql
process_resident_memory_bytes{job="octocat-supply"}
```

> **왜 중요한가:** 메모리 누수 탐지의 핵심.
> 시간이 지나면서 꾸준히 올라가면 메모리 누수 의심.
> 컨테이너 memory limit에 근접하면 OOM Kill 위험.

검증 결과:
```
VM:  98.0 MB
AKS: 92.1 MB
```

### 4-2. V8 Heap 사용량

```promql
nodejs_heap_size_used_bytes{job="octocat-supply"}
```

> RSS와 Heap 차이가 크면 native 모듈(better-sqlite3 등)이 메모리를 쓰고 있다는 뜻.

검증 결과:
```
VM:  22.7 MB (RSS 98MB 중 Heap은 23MB → native 모듈이 ~75MB 사용)
AKS: 20.8 MB
```

### 4-3. Heap 사용률 (OOM 위험도)

```promql
nodejs_heap_size_used_bytes{job="octocat-supply"}
/
nodejs_heap_size_total_bytes{job="octocat-supply"}
```

> 80% 이상이면 GC 부하 증가, V8 OOM 위험.

### 4-4. CPU 사용률

```promql
rate(process_cpu_seconds_total{job="octocat-supply"}[5m])
```

> 결과가 1.0 = CPU 코어 1개 100% 사용. Node.js는 싱글 스레드이므로 1.0에 가까우면 병목.

검증 결과:
```
VM:  1.29% (여유 충분)
AKS: 6.01%
```

### 4-5. Event Loop Lag (Node.js 고유 지표)

```promql
nodejs_eventloop_lag_seconds{job="octocat-supply"}
```

> **왜 중요한가:** Node.js 성능의 핵심 지표.
> Event Loop이 막히면 모든 요청이 느려진다.
> 10ms 이하: 정상 / 50ms 이상: 성능 저하 / 100ms 이상: 심각한 블로킹.

검증 결과:
```
VM:  3.48 ms ✅ (정상)
AKS: 2.45 ms ✅ (정상)
```

### 4-6. Event Loop Lag P99 (순간 스파이크 감지)

```promql
nodejs_eventloop_lag_p99_seconds{job="octocat-supply"}
```

> 평균 lag은 낮은데 P99가 높으면 간헐적 블로킹 발생 중.

### 4-7. GC (가비지 컬렉션) 시간

```promql
rate(nodejs_gc_duration_seconds_sum{job="octocat-supply"}[5m])
```

> **왜 중요한가:** GC가 오래 걸리면 Event Loop이 멈춘다.
> kind별로 확인: `major`가 높으면 Old Space 메모리 압박.

검증 결과:
```
VM:  minor = 0.507 ms/s, major = 0.018 ms/s, incremental = 0.023 ms/s
     → minor GC가 대부분, major는 거의 없음 = 건강한 상태 ✅
```

### 4-8. Active Handles & Open File Descriptors

```promql
nodejs_active_handles_total{job="octocat-supply"}
process_open_fds{job="octocat-supply"}
```

> 시간 경과에 따라 계속 증가하면 리소스 누수 (연결 미해제, 파일 미닫힘).

검증 결과:
```
VM:  Active Handles = 4, Open FDs = 39 (안정적)
```

---

## 5. MetricsQL 확장 기능 (Prometheus에서는 안 되는 것)

### 5-1. lookbehind window 자동 선택

```promql
# Prometheus: 반드시 [5m] 같은 window 필요
rate(http_requests_total{job="octocat-supply"}[5m])

# VictoriaMetrics MetricsQL: window 생략 가능 (자동 최적 선택)
rate(http_requests_total{job="octocat-supply"})
```

검증 결과:
```
VM:  auto-window rate = 0.9333 req/s (수동 [5m]과 동일 결과 ✅)
```

> **장점:** scrape_interval 변경 시 쿼리 수정 불필요.
> **주의:** Grafana 대시보드를 Prometheus로 마이그레이션할 때는 window 명시 필요.

### 5-2. default 연산자 (빈 결과 처리)

```promql
# Prometheus: 데이터 없으면 그래프에 빈 구간
rate(http_requests_total{path="/nonexistent"}[5m])

# VictoriaMetrics: 없으면 0으로 채우기
rate(http_requests_total{path="/nonexistent"}[5m]) default 0
```

검증 결과:
```
VM:  value = 0 (데이터 없는 경로도 0으로 표시 ✅)
```

> **유용한 상황:** 대시보드에서 "No data" 대신 0을 보여주고 싶을 때.
> 에러율 계산에서 분모가 0일 때 NaN 방지.

### 5-3. keep_last_value (gap 채우기)

```promql
# 앱 재시작 등으로 scrape 실패 시 마지막 값 유지
keep_last_value(process_resident_memory_bytes{job="octocat-supply"})
```

> Prometheus: 5분 후 stale 마킹 → 그래프 끊김
> VictoriaMetrics: `keep_last_value()`로 연속 그래프 유지

### 5-4. label 조작 함수

```promql
# 환경 라벨 추가
label_set(up{job="octocat-supply"}, "env", "poc")

# 불필요한 instance 라벨 제거
label_del(http_requests_total{job="octocat-supply"}, "instance")
```

> Prometheus에서는 relabeling 설정 파일에서만 가능했던 것을 쿼리 시점에서 처리.

### 5-5. range_last / range_first

```promql
# 5분간의 마지막 값
range_last(http_requests_total{job="octocat-supply"}[5m])
```

---

## 6. Prometheus vs VictoriaMetrics 쿼리 비교

### 동일하게 동작하는 쿼리 (마이그레이션 안전)

| 쿼리 | 동작 |
|------|------|
| `rate(x[5m])` | ✅ 동일 |
| `sum by (label) (rate(x[5m]))` | ✅ 동일 |
| `histogram_quantile(0.95, ...)` | ✅ 동일 |
| `increase(x[1h])` | ✅ 동일 |
| `avg_over_time(x[5m])` | ✅ 동일 |
| `topk(5, rate(x[5m]))` | ✅ 동일 |

### VictoriaMetrics에서만 가능한 쿼리

| 기능 | MetricsQL | Prometheus |
|------|----------|-----------|
| window 생략 | `rate(x)` | ❌ 에러 |
| 빈 값 기본값 | `rate(x[5m]) default 0` | ❌ 없음 |
| gap 유지 | `keep_last_value(x)` | ❌ 없음 |
| 쿼리 시 라벨 변경 | `label_set(x, "k", "v")` | ❌ 없음 |
| 범위 첫/끝 값 | `range_first(x[5m])` | ❌ 없음 |
| 중간값 | `median(x)` | ❌ `quantile(0.5, x)` 필요 |
| 카운팅 | `count_values_over_time(x[5m])` | ❌ 없음 |

### rate() 동작 차이

```promql
rate(http_requests_total[5m])
```

| 항목 | Prometheus | VictoriaMetrics |
|------|-----------|----------------|
| Extrapolation | 시간 범위 외삽 → 실제보다 높게 나올 수 있음 | counter 증가분 기반 → 더 정확 |
| Counter reset 처리 | 단순 증가분 | 더 정교한 reset 감지 |
| 마지막 scrape 누락 | stale 마킹 | 설정 가능 (`keep_last_value`) |

---

## 7. 운영 알림 추천 룰

실제 서비스에서 설정하면 좋은 알림 기준:

```yaml
# victoriametrics alert rules 형식
groups:
  - name: octocat-supply
    rules:
    # 5xx 에러율 1% 초과 (5분간)
    - alert: HighErrorRate
      expr: |
        sum(rate(http_requests_total{job="octocat-supply", status=~"5.."}[5m]))
        / sum(rate(http_requests_total{job="octocat-supply"}[5m]))
        > 0.01
      for: 5m

    # P95 응답시간 500ms 초과
    - alert: HighLatency
      expr: |
        histogram_quantile(0.95,
          sum by (le) (rate(http_request_duration_seconds_bucket{job="octocat-supply"}[5m]))
        ) > 0.5
      for: 5m

    # Event Loop Lag 50ms 초과
    - alert: EventLoopBlocked
      expr: nodejs_eventloop_lag_seconds{job="octocat-supply"} > 0.05
      for: 3m

    # 메모리 400MB 초과 (컨테이너 limit 512MB 기준)
    - alert: HighMemory
      expr: process_resident_memory_bytes{job="octocat-supply"} > 400*1024*1024
      for: 10m

    # 타겟 다운
    - alert: TargetDown
      expr: up{job="octocat-supply"} == 0
      for: 1m
```

---

## 8. 쿼리 작성 시 주의사항

### rate() range 선택

```promql
# scrape_interval이 10s일 때:
rate(x[10s])  # ❌ 데이터 포인트 1~2개 → 부정확
rate(x[30s])  # ⚠️ 최소한이지만 불안정
rate(x[1m])   # ✅ 적절 (6개 포인트)
rate(x[5m])   # ✅ 안정적 (30개 포인트)
```

> **규칙:** range는 scrape_interval의 최소 4배 이상 사용.

### label cardinality 주의

```promql
# ❌ 위험: /api/products/1, /api/products/2... 무한 증가
http_requests_total{path=~"/api/products/.*"}

# ✅ 안전: 정규화된 경로 또는 집계
sum by (method) (rate(http_requests_total[5m]))
```

> label 값이 무한히 늘어나면 VictoriaMetrics 메모리/디스크를 소모한다.
> `req.originalUrl` 대신 라우트 패턴 (`/api/products/:id`)으로 정규화하는 것이 프로덕션 모범 사례.

### counter vs gauge 구분

```promql
# counter (누적값) → rate() 또는 increase() 사용
rate(http_requests_total[5m])       # ✅ 초당 변화율
increase(http_requests_total[1h])   # ✅ 1시간 증가량
http_requests_total                 # ⚠️ 누적값 그 자체 (그래프로 무의미)

# gauge (현재값) → 그대로 사용
process_resident_memory_bytes       # ✅ 현재 메모리
nodejs_eventloop_lag_seconds        # ✅ 현재 lag
```

---

## 참고

- [MetricsQL 공식 문서](https://docs.victoriametrics.com/metricsql/)
- [MetricsQL vs PromQL 비교](https://docs.victoriametrics.com/metricsql/#metricsql-features)
- [VictoriaMetrics Alerting](https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/#alerting)
- [USE Method (Brendan Gregg)](https://www.brendangregg.com/usemethod.html) - 시스템 성능 분석 프레임워크
- [RED Method (Tom Wilkie)](https://grafana.com/blog/2018/08/02/the-red-method-how-to-instrument-your-services/) - 서비스 모니터링 프레임워크
