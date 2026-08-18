# 카디널리티(Cardinality) 개념과 운영 — VictoriaMetrics 실측 기반

> 📚 [← 전체 개요(README)](../README.md) · [쿼리 가이드](query-guide.md)

시계열 DB(Prometheus/VictoriaMetrics) 운영에서 **가장 흔한 장애 원인이자 비용 요인**이 카디널리티입니다.
이 문서는 본 PoC의 VM(`env="poc"`)에서 실제 측정한 값으로 개념을 설명합니다.

---

## 1. 카디널리티란?

**카디널리티 = 저장된 고유 시계열(time series)의 개수.**

하나의 시계열은 **메트릭 이름 + 라벨 조합**으로 유일하게 식별됩니다.

```
http_requests_total{method="GET", route="/api/products", status="200"}   ← 시계열 1개
http_requests_total{method="GET", route="/api/products", status="404"}   ← 또 다른 시계열
http_requests_total{method="POST",route="/api/orders",   status="200"}   ← 또 다른 시계열
```

즉 **라벨 값의 조합 수만큼 시계열이 생깁니다.**

### 카디널리티 계산 공식

```
시계열 수 ≈ (메트릭 수) × (라벨A 값 수) × (라벨B 값 수) × ...
```

라벨이 늘거나 라벨 값의 종류가 늘면 **곱셈으로 폭발**합니다. 이게 "cardinality explosion".

---

## 2. 본 PoC 실측 (VM `/api/v1/status/tsdb`)

VictoriaMetrics는 카디널리티 통계를 API로 제공합니다:

```bash
curl -s "http://<VM_PUBIP>:8428/api/v1/status/tsdb"
```

| 항목 | 실측값 |
|------|--------|
| **totalSeries** (총 시계열) | **153** |
| totalLabelValuePairs | 1,163 |
| 최다 시계열 메트릭 | `http_request_duration_seconds_bucket` = **33** |
| 2위 | `nodejs_gc_duration_seconds_bucket` = 21 |

라벨별 고유값 수(실측):

| 라벨 | 고유값 수 | 값 예시 |
|------|-----------|---------|
| `__name__` | 49 | 메트릭 종류 |
| `le` | 13 | 히스토그램 버킷 경계 (`0.005`, `0.01`, …, `+Inf`) |
| `route` | 3 | `/`, `/metrics`, `/nonexistent` |
| `status` | 2 | `200`, `404` |
| `app`/`instance` | 1 | 단일 앱 |

---

## 3. 왜 히스토그램이 카디널리티를 많이 먹나 (실측 사례)

`http_request_duration_seconds_bucket` 하나가 **33 시계열** — 전체(153)의 20%가 넘습니다. 이유:

```
bucket 시계열 = route(3) × status(2) × le(13) ≈ 여러 조합
```

히스토그램은 `le`(버킷 경계) 라벨마다 별도 시계열이 생깁니다. **버킷을 잘게 나눌수록**(미들웨어의 `buckets` 배열이 길수록) 카디널리티가 커집니다.

> **실무 팁:** 지연시간 정밀도(버킷 수)와 카디널리티는 트레이드오프입니다. 필요 이상으로 촘촘한 버킷은 피하세요. 본 PoC는 10개 경계를 씁니다.

---

## 4. 카디널리티 폭발 시나리오 (곱셈의 무서움)

`route` 라벨에 **정규화된 경로** 대신 **실제 URL(ID 포함)**을 넣으면:

| 라벨 설계 | route 값 수 | http_requests_total 시계열 |
|-----------|-------------|----------------------------|
| ✅ `/api/products/:id` (정규화) | 3 | ~3 (현재) |
| ❌ `/api/products/123`, `/456`… | 사용자 수만큼 (예: 100,000) | **100,000 × status × method** |

여기에 `user_id`, `request_id`, `timestamp`, `session` 같은 **무한 값 라벨**을 넣으면 시계열이 수백만~수천만으로 폭발합니다.

### 폭발이 일으키는 실제 문제
- **메모리 폭증** — active series가 RAM에 인덱싱됨 → OOM
- **쿼리 지연/실패** — 매칭 시계열이 많아 느려지고 타임아웃
- **디스크/비용 증가**
- vmsingle이면 **단일 노드 한계**에 빠르게 도달 ([scaling 문서](scaling.md) 참고)

---

## 5. 절대 라벨에 넣으면 안 되는 값 (high-cardinality)

| 안티패턴 라벨 | 이유 |
|---------------|------|
| `user_id`, `email` | 사용자 수만큼 무한 |
| `request_id`, `trace_id` | 요청마다 고유 → 무한 |
| `/api/products/123` (raw path) | ID가 값이 됨 → 정규화 필수 |
| `timestamp`, `epoch` | 매번 새 값 |
| 전체 URL/쿼리스트링 | 조합 폭발 |
| IP 주소(공개 트래픽) | 사실상 무한 |

> **원칙:** 라벨 값은 **유한하고 낮은 카디널리티**(상태, 메서드, 정규화된 경로, 리전, 환경 등)여야 합니다. 고유 식별자는 **로그/트레이싱**으로 보내지 메트릭 라벨로 쓰지 않습니다.

---

## 6. 카디널리티 진단 쿼리 (✅ 실측 가능)

```bash
# 총 시계열 수
curl -s "$VM/api/v1/query" --data-urlencode 'query=count({__name__=~".+"})'      # -> 133~153

# 메트릭별 시계열 수 (어떤 메트릭이 비싼가)
curl -s "$VM/api/v1/query" --data-urlencode 'query=count by (__name__)({__name__=~".+"})'

# 특정 메트릭의 라벨 조합 수
curl -s "$VM/api/v1/query" --data-urlencode 'query=count(http_requests_total)'

# 내장 통계 (가장 강력)
curl -s "$VM/api/v1/status/tsdb"          # seriesCountByMetricName/LabelName
```

VictoriaMetrics는 **vmui에 "Cardinality explorer"** 도 내장합니다:
```
http://<VM_PUBIP>:8428/vmui  →  상단 메뉴 "Explore cardinality"
```
메트릭별/라벨별 시계열 수를 시각적으로 보여줘, 범인 라벨을 바로 찾을 수 있습니다.

---

## 7. VictoriaMetrics의 카디널리티 대응 기능

| 기능 | 설명 |
|------|------|
| `-maxLabelsPerTimeseries` | 시계열당 라벨 수 제한 |
| `-search.maxUniqueTimeseries` | 쿼리당 시계열 상한 (폭발 쿼리 차단) |
| **Cardinality explorer** (vmui 내장) | 고카디널리티 원인 진단 |
| stream aggregation (vmagent) | 저장 전 집계로 카디널리티 축소 |
| `-storage.maxHourlySeries` / `maxDailySeries` | 신규 시계열 유입 속도 제한 |

> Prometheus 대비 강점: VictoriaMetrics는 **고카디널리티에서 메모리 효율이 좋고**, 위 진단/제한 도구가 기본 내장이라 운영 대응이 쉽습니다. (단, 근본 해법은 항상 **라벨 설계**입니다.)

---

## 8. 핵심 요약

1. **카디널리티 = 고유 시계열 수**, 라벨 조합의 **곱**으로 늘어난다
2. 히스토그램(`le`)·라벨 추가는 카디널리티를 배수로 키운다 (실측: bucket 33/153)
3. **무한 값(user_id, request_id, raw path)을 라벨에 넣지 마라** — 폭발의 주원인
4. `route`는 반드시 `:id`로 정규화 (본 PoC의 알려진 관찰점과 연결)
5. 진단은 `/api/v1/status/tsdb` + vmui **Cardinality explorer**
6. 확장 한계와 직결 → [scaling 문서](scaling.md)의 vmsingle→vmcluster 판단과 함께 보라
