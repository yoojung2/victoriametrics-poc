# Step 2 — 앱 계측(prom-client)으로 실제 앱 메트릭 수집

> 📚 [← 전체 개요(README)](../README.md) · [Step 1: 설치](step1-install.md) · **Step 2: 앱 메트릭 연동**

Step 1에서 만든 VictoriaMetrics에, **실제 애플리케이션([octocat-supply](https://github.com/Azure-Samples/octocat-supply))의 트래픽 메트릭**을 흘려보내 vmui에서 쿼리로 확인합니다.

## 전체 구조

```
[octocat API + prom-client] --/metrics--> [vmagent] --remote_write--> [VictoriaMetrics :8428]
        ↑ loadgen.sh 가 트래픽 발생                (scrape 10s)              ↑ vmui 에서 쿼리
```

| 구성요소 | 역할 |
|----------|------|
| octocat-supply API | Express 앱. **prom-client 계측 추가**로 `/metrics` 노출 |
| vmagent | `/metrics`를 스크레이프 → VictoriaMetrics로 `remote_write` |
| VictoriaMetrics | Step 1의 VM(`:8428`)에서 저장/쿼리 |
| loadgen.sh | API에 HTTP 트래픽 발생 |

> **왜 계측이 필요한가?** octocat-supply는 기본적으로 `/metrics`가 **없습니다**(`prom-client` 미포함). 실제로 확인하면 404가 납니다:
> ```bash
> $ curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000/metrics
> 404          # Cannot GET /metrics
> ```
> 그래서 아래처럼 계측 코드를 추가해 200으로 만듭니다.

---

## 1. prom-client 계측 추가

### 1-1. 의존성 설치

```bash
cd octocat-supply/api
npm install prom-client
```

### 1-2. 계측 미들웨어 추가

[`step2/app/metrics-middleware.ts`](../step2/app/metrics-middleware.ts) 를 `api/src/metrics-middleware.ts` 로 복사합니다. 핵심:

- `collectDefaultMetrics()` — Node.js 프로세스 메트릭(CPU/메모리/GC 등) 자동 수집
- `http_requests_total` (Counter) — `method`/`route`/`status` 라벨별 요청 수
- `http_request_duration_seconds` (Histogram) — 요청 지연시간 분포

### 1-3. index.ts 연결

[`step2/app/index.ts.patch`](../step2/app/index.ts.patch) 참고. 실제 적용한 변경은 단 3곳:

```diff
 import { errorHandler } from './utils/errors';
+import { metricsMiddleware, metricsHandler } from './metrics-middleware';

 app.use(express.json());

+// Prometheus 계측: 모든 라우트보다 먼저 등록해 요청 수/지연시간 수집
+app.use(metricsMiddleware);
+// Prometheus 스크레이프 엔드포인트
+app.get('/metrics', metricsHandler);

 app.use('/api/deliveries', deliveryRoutes);
```

---

## 2. 앱 실행 후 /metrics 확인 (검증 완료)

```bash
cd octocat-supply/api
npm run dev          # -> Server is running on port 3000
```

```bash
# 상태코드 확인
$ curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000/metrics
200                                     # ← 이제 200! (계측 전에는 404)

# 트래픽 발생 후 계측 카운터 확인
$ curl -s http://localhost:3000/metrics | grep '^http_requests_total'
http_requests_total{method="GET",route="/metrics",status="200"} 1
http_requests_total{method="GET",route="/",status="200"} 30
http_requests_total{method="GET",route="/nonexistent",status="404"} 15
```

정상 동작 확인 ✓ (요청 수가 라벨별로 집계되고, 404도 별도 status로 잡힘)

> ⚠️ **알려진 관찰점 — route 라벨 세분화**
> Express 서브라우터(`app.use('/api/products', router)`)는 `req.route.path`가 `/`로 잡혀
> `/api/products`, `/api/branches` 등이 route=`/`로 합쳐집니다.
> 엔드포인트별로 나누려면 미들웨어에서 `req.baseUrl + (req.route?.path||'')`를 route 라벨로 쓰세요.
> (`metrics-middleware.ts` 주석에도 기록해 둠)

---

## 3. vmagent로 스크레이프 → VictoriaMetrics remote_write

Docker 없이 바이너리로 실행하는 예시입니다. ([`step2/vmagent/scrape.yml`](../step2/vmagent/scrape.yml))

```bash
# vmagent 바이너리 다운로드 (vmutils 번들에 포함)
VM_VERSION=$(curl -s https://api.github.com/repos/VictoriaMetrics/VictoriaMetrics/releases/latest \
  | grep -oP '"tag_name":\s*"\K[^"]+')
wget "https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/${VM_VERSION}/vmutils-linux-amd64-${VM_VERSION}.tar.gz"
tar -xzf vmutils-linux-amd64-${VM_VERSION}.tar.gz   # -> vmagent-prod 등 포함

# 스크레이프 + remote_write 실행 (VM_PUBIP = Step 1의 VM Public IP)
./vmagent-prod \
  -promscrape.config=step2/vmagent/scrape.yml \
  -remoteWrite.url=http://<VM_PUBIP>:8428/api/v1/write
```

`scrape.yml` 요약:
```yaml
global:
  scrape_interval: 10s
scrape_configs:
  - job_name: octocat-api
    metrics_path: /metrics
    static_configs:
      - targets: ['localhost:3000']
        labels: { app: octocat-api }
```

---

## 4. 트래픽 발생

[`scripts/loadgen.sh`](../scripts/loadgen.sh) — 여러 엔드포인트에 60초간 요청을 섞어 보냅니다(정상 + 404).

```bash
./scripts/loadgen.sh http://localhost:3000 60
```

---

## 5. VictoriaMetrics(vmui)에서 쿼리 확인

`http://<VM_PUBIP>:8428/vmui` 접속 후 아래 쿼리:

| 쿼리 | 의미 |
|------|------|
| `http_requests_total` | 라벨별 누적 요청 수 |
| `rate(http_requests_total[1m])` | 초당 요청률(RPS) |
| `sum by (status) (rate(http_requests_total[1m]))` | 상태코드별 RPS (2xx/4xx) |
| `histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))` | p95 응답시간 |
| `process_resident_memory_bytes{app="octocat-api"}` | 앱 메모리 사용량 |

CLI로도 확인 가능:
```bash
curl -s "http://<VM_PUBIP>:8428/api/v1/query?query=http_requests_total" | jq .
```

---

## 트러블슈팅

| 증상 | 원인/해결 |
|------|-----------|
| `/metrics` 404 | 계측 미적용. 미들웨어/라우트 등록 확인, `app.use(metricsMiddleware)`가 라우트보다 위인지 확인 |
| vmui에 데이터 없음 | vmagent `-remoteWrite.url` 오타/포트, VM NSG 8428 인바운드 확인 |
| route 라벨이 전부 `/` | 위 "알려진 관찰점" 참고 — `req.baseUrl` 조합 사용 |
| 카운터가 안 올라감 | 미들웨어가 `res.on('finish')`에서 집계 — 응답이 끝나야 반영됨 |

---

## 이 단계에서 실제로 만든 파일

```
step2/
├── app/
│   ├── metrics-middleware.ts   # prom-client 계측 미들웨어 (api/src/에 복사)
│   └── index.ts.patch          # index.ts 연결 diff (3곳 변경)
└── vmagent/
    └── scrape.yml              # vmagent 스크레이프 설정
scripts/
└── loadgen.sh                  # 트래픽 생성기
```
