# Step 2: 샘플 앱(octocat-supply) 배포 & 메트릭 수집

octocat-supply 앱을 VM에 배포하고, prom-client로 계측하여 VictoriaMetrics가 scrape → vmui에서 쿼리 확인하는 전체 과정입니다.

## 전체 아키텍처

```
┌─────────────────────────────────────────────────────────┐
│  Azure VM (vm-victoriametrics)                          │
│                                                         │
│  ┌────────────────────┐     ┌───────────────────────┐  │
│  │ octocat-supply API │     │ VictoriaMetrics       │  │
│  │ :3000              │     │ :8428                 │  │
│  │                    │     │                       │  │
│  │ GET /metrics ◀─────┼─────┤ promscrape (10s)     │  │
│  │  (prom-client)     │     │                       │  │
│  └────────────────────┘     └───────────────────────┘  │
│                                       │                 │
│                                       ▼                 │
│                                 vmui 대시보드           │
│                              http://<IP>:8428/vmui      │
└─────────────────────────────────────────────────────────┘
```

---

## 사전 조건

- Step 1 완료 (VM에 VictoriaMetrics가 `active (running)` 상태)
- VM SSH 접속 가능

```bash
VM_IP=$(az vm show -d -g rg-victoriametrics -n vm-victoriametrics --query publicIps -o tsv)
ssh azureuser@$VM_IP
```

---

## 2-1. Node.js & 빌드 도구 설치

> ⚠️ `better-sqlite3` 네이티브 모듈 빌드를 위해 `build-essential`이 필요합니다.

```bash
# Node.js 18.x
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs make git

# C/C++ 컴파일러 (네이티브 모듈 빌드용)
sudo apt-get install -y build-essential python3

# 확인
node -v   # v18.x
npm -v    # 10.x
```

---

## 2-2. octocat-supply 앱 클론 & 설치

```bash
cd ~
git clone https://github.com/Azure-Samples/octocat-supply.git
cd octocat-supply
make install
```

> `make install`은 `api/`와 `frontend/` 각각 `npm install`을 실행합니다.
> `better-sqlite3` 빌드 경고가 뜨지만, `build-essential`이 있으면 정상 완료됩니다.

---

## 2-3. prom-client 설치 & 계측 코드 추가

### 패키지 설치

```bash
cd ~/octocat-supply/api
npm install prom-client
```

### `api/src/index.ts` 수정

파일 최상단에 import 추가:

```typescript
import { collectDefaultMetrics, register, Counter, Histogram } from "prom-client";
```

`const app = express();` 바로 아래에 다음 코드 추가:

```typescript
// --- Prometheus Metrics ---
collectDefaultMetrics();

const httpRequestsTotal = new Counter({
  name: "http_requests_total",
  help: "Total HTTP requests",
  labelNames: ["method", "path", "status"],
});

const httpRequestDuration = new Histogram({
  name: "http_request_duration_seconds",
  help: "HTTP request duration in seconds",
  labelNames: ["method", "path"],
  buckets: [0.01, 0.05, 0.1, 0.5, 1, 5],
});

// Metrics middleware
app.use((req, res, next) => {
  const end = httpRequestDuration.startTimer({ method: req.method, path: req.path });
  res.on("finish", () => {
    httpRequestsTotal.inc({ method: req.method, path: req.path, status: String(res.statusCode) });
    end();
  });
  next();
});

// Metrics endpoint
app.get("/metrics", async (_req, res) => {
  res.set("Content-Type", register.contentType);
  res.end(await register.metrics());
});
// --- End Prometheus Metrics ---
```

> 💡 미들웨어는 라우트 등록 전에 위치해야 모든 요청을 계측할 수 있습니다.

---

## 2-4. 앱 실행 & /metrics 확인

```bash
cd ~/octocat-supply/api
npx tsx src/index.ts &
```

정상 시작 로그:
```
🚀 Initializing database...
🎉 Database seeding completed successfully!
✅ Database initialized successfully
Server is running on port 3000
```

메트릭 엔드포인트 확인:
```bash
curl http://localhost:3000/metrics | head -20
```

예상 응답:
```
# HELP process_cpu_user_seconds_total Total user CPU time spent in seconds.
# TYPE process_cpu_user_seconds_total counter
process_cpu_user_seconds_total 0.224872
...
# HELP http_requests_total Total HTTP requests
# TYPE http_requests_total counter
```

---

## 2-5. VictoriaMetrics promscrape 설정

```bash
# scrape 설정 파일 생성
sudo mkdir -p /etc/victoriametrics
sudo tee /etc/victoriametrics/promscrape.yml <<EOF
scrape_configs:
  - job_name: 'octocat-supply'
    scrape_interval: 10s
    static_configs:
      - targets: ['localhost:3000']
    metrics_path: '/metrics'
EOF
```

systemd 서비스에 `-promscrape.config` 옵션 추가:

```bash
sudo sed -i 's|ExecStart=.*|ExecStart=/usr/local/bin/victoria-metrics -storageDataPath=/var/lib/victoria-metrics-data -httpListenAddr=:8428 -retentionPeriod=30d -promscrape.config=/etc/victoriametrics/promscrape.yml|' /etc/systemd/system/victoriametrics.service

sudo systemctl daemon-reload
sudo systemctl restart victoriametrics
```

### scrape 상태 확인

```bash
curl http://localhost:8428/targets
```

예상 응답:
```
job=octocat-supply (1/1 up)
  state=up, endpoint=http://localhost:3000/metrics,
  labels={instance="localhost:3000",job="octocat-supply"},
  scrapes_total=4, scrapes_failed=0, last_scrape=4.972s ago,
  samples_scraped=119, error=
```

> `state=up`이면 정상 수집 중!

---

## 2-6. 트래픽 생성

```bash
# 단발 부하 (50회 × 3 API = 150 요청)
for i in $(seq 1 50); do
  curl -s http://localhost:3000/api/products > /dev/null
  curl -s http://localhost:3000/api/orders > /dev/null
  curl -s http://localhost:3000/api/branches > /dev/null
done

# 지속적 트래픽 (백그라운드, Ctrl+C로 중지)
while true; do
  curl -s http://localhost:3000/api/products > /dev/null
  curl -s http://localhost:3000/api/orders > /dev/null
  sleep 1
done &
```

---

## 2-7. vmui에서 쿼리 확인

브라우저: `http://<VM_PUBLIC_IP>:8428/vmui`

### 수집 확인

```promql
# scrape target 상태 (1 = UP)
up{job="octocat-supply"}

# 수집된 전체 메트릭 목록
{job="octocat-supply"}
```

### HTTP 트래픽 분석

```promql
# 초당 요청 수 (RPS)
rate(http_requests_total{job="octocat-supply"}[1m])

# 경로별 RPS
sum by (path) (rate(http_requests_total[1m]))

# 상태코드별 분포
sum by (status) (http_requests_total)
```

### 응답 시간 분석

```promql
# 평균 응답 시간
rate(http_request_duration_seconds_sum[1m]) / rate(http_request_duration_seconds_count[1m])

# P95 응답 시간
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))
```

### Node.js 런타임 메트릭

```promql
# 메모리 사용량
process_resident_memory_bytes{job="octocat-supply"}

# CPU 사용률
rate(process_cpu_seconds_total{job="octocat-supply"}[1m])

# Event Loop Lag
nodejs_eventloop_lag_seconds
```

---

## 2-8. (선택) NSG 포트 오픈 - 외부에서 vmui 접근

```bash
az vm open-port \
  --resource-group rg-victoriametrics \
  --name vm-victoriametrics \
  --port 8428 \
  --priority 1010
```

> ⚠️ 테스트 후 삭제하거나 특정 IP만 허용하세요.

---

## 실제 검증 결과

| 항목 | 결과 |
|------|------|
| 앱 실행 | ✅ port 3000 정상 기동 |
| /metrics 응답 | ✅ Prometheus 포맷 출력 (119 samples) |
| VictoriaMetrics scrape | ✅ `state=up`, `scrapes_failed=0` |
| 수집된 메트릭 | ✅ `http_requests_total`, `http_request_duration_seconds`, `process_*`, `nodejs_*` 등 42종 |
| vmui 쿼리 | ✅ `rate(http_requests_total[1m])` 등 정상 조회 |

---

## 트러블슈팅

| 문제 | 원인 | 해결 |
|------|------|------|
| `make install` 실패 (better-sqlite3) | C 컴파일러 없음 | `sudo apt-get install -y build-essential` |
| `/metrics` 404 | prom-client 코드 미적용 | 2-3 단계 코드 추가 확인 |
| targets에서 `state=down` | 앱이 안 떠있음 | `npx tsx src/index.ts` 실행 확인 |
| 쿼리 결과 비어있음 | scrape 직후 (데이터 미적재) | 10~15초 대기 후 재시도 |

---

## 참고

- [octocat-supply 저장소](https://github.com/Azure-Samples/octocat-supply)
- [prom-client (Node.js Prometheus client)](https://github.com/siimon/prom-client)
- [VictoriaMetrics promscrape 설정](https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/#how-to-scrape-prometheus-exporters-such-as-node-exporter)
- [vmui 사용법](https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/#vmui)
