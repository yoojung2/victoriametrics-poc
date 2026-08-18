# Step 3: AKS 환경 전체 구성 (컨테이너 기반)

VM에서 수행한 동일한 파이프라인을 AKS(Kubernetes) 환경에서 구현합니다.

## 아키텍처

```
┌──────────────────────────────────────────────────────────────┐
│  AKS Cluster (aks-victoriametrics, koreacentral)             │
│  Namespace: vm                                               │
│                                                              │
│  ┌────────────────────┐    ┌──────────────────────────────┐  │
│  │ octocat-supply     │    │ VictoriaMetrics              │  │
│  │ Deployment (x2)    │    │ StatefulSet (Helm)           │  │
│  │ :3000              │    │ :8428                        │  │
│  │                    │    │                              │  │
│  │ GET /metrics ◀─────┼────┤ promscrape (ConfigMap)      │  │
│  │  (prom-client)     │    │ scrape_interval: 10s         │  │
│  └────────────────────┘    └──────────────────────────────┘  │
│                                                              │
│  ┌────────────────────┐                                      │
│  │ loadgen-24h Pod    │                                      │
│  │ busybox            │                                      │
│  │ 7 endpoints/sec    │──── octocat-supply:3000              │
│  │ 24h TTL            │                                      │
│  └────────────────────┘                                      │
│                                                              │
│  ┌────────────────────┐                                      │
│  │ ACR (acrvmpoc)     │                                      │
│  │ octocat-supply-    │                                      │
│  │ api:v1             │                                      │
│  └────────────────────┘                                      │
└──────────────────────────────────────────────────────────────┘
```

---

## 구성 컴포넌트

| 컴포넌트 | 유형 | 설명 |
|---------|------|------|
| ACR (`acrvmpoc`) | Azure Container Registry | 앱 이미지 저장소 |
| octocat-supply | Deployment (2 replicas) | prom-client 계측된 Express API |
| VictoriaMetrics | StatefulSet (Helm) | 메트릭 수집/저장/쿼리 |
| vm-promscrape | ConfigMap | scrape 설정 파일 |
| loadgen-24h | Pod (busybox) | 24시간 부하 생성기 |

---

## 사전 조건

- Step 1 완료 (AKS 클러스터 생성됨)
- `kubectl` 컨텍스트 설정

```bash
az aks get-credentials --resource-group rg-victoriametrics --name aks-victoriametrics --overwrite-existing
kubectl get nodes
```

---

## 3-1. ACR 생성 & AKS 연결

```bash
# ACR 생성
az acr create --resource-group rg-victoriametrics --name acrvmpoc --sku Basic

# AKS에서 ACR pull 권한 부여
az aks update --resource-group rg-victoriametrics --name aks-victoriametrics --attach-acr acrvmpoc
```

---

## 3-2. 앱 이미지 빌드 (ACR Tasks)

```bash
# 소스 클론
git clone https://github.com/Azure-Samples/octocat-supply.git
cd octocat-supply/api

# prom-client 설치
npm install prom-client
```

### `src/index.ts` 수정 (Step 2와 동일)

파일 최상단:
```typescript
import { collectDefaultMetrics, register, Counter, Histogram } from "prom-client";
```

`const app = express();` 아래:
```typescript
collectDefaultMetrics();
const httpRequestsTotal = new Counter({
  name: "http_requests_total",
  help: "Total HTTP requests",
  labelNames: ["method", "path", "status"],
});
const httpRequestDuration = new Histogram({
  name: "http_request_duration_seconds",
  help: "HTTP request duration",
  labelNames: ["method", "path"],
  buckets: [0.01, 0.05, 0.1, 0.5, 1, 5],
});

// ⚠️ req.originalUrl 사용 (라우터 마운트 포인트 포함)
app.use((req, res, next) => {
  const end = httpRequestDuration.startTimer({ method: req.method, path: req.originalUrl });
  res.on("finish", () => {
    httpRequestsTotal.inc({ method: req.method, path: req.originalUrl, status: String(res.statusCode) });
    end();
  });
  next();
});

app.get("/metrics", async (_req, res) => {
  res.set("Content-Type", register.contentType);
  res.end(await register.metrics());
});
```

### Dockerfile 작성

```dockerfile
FROM node:18-slim

RUN apt-get update && apt-get install -y build-essential python3 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .

EXPOSE 3000
CMD ["npx", "tsx", "src/index.ts"]
```

### ACR에서 빌드 & 푸시

```bash
az acr build --registry acrvmpoc --image octocat-supply-api:v1 .
```

---

## 3-3. Namespace 생성

```bash
kubectl create namespace vm
```

---

## 3-4. VictoriaMetrics 설치 (Helm)

```bash
helm repo add vm https://victoriametrics.github.io/helm-charts/
helm repo update

helm install vmsingle vm/victoria-metrics-single \
  --namespace vm \
  --set server.persistentVolume.size=10Gi
```

---

## 3-5. octocat-supply 배포

```yaml
# octocat-supply.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: octocat-supply
  namespace: vm
spec:
  replicas: 2
  selector:
    matchLabels:
      app: octocat-supply
  template:
    metadata:
      labels:
        app: octocat-supply
    spec:
      containers:
      - name: api
        image: acrvmpoc.azurecr.io/octocat-supply-api:v1
        ports:
        - containerPort: 3000
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: octocat-supply
  namespace: vm
spec:
  selector:
    app: octocat-supply
  ports:
  - port: 3000
    targetPort: 3000
```

```bash
kubectl apply -f octocat-supply.yaml
```

---

## 3-6. promscrape 설정 & VictoriaMetrics 연결

```yaml
# promscrape-cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: vm-promscrape
  namespace: vm
data:
  promscrape.yml: |
    scrape_configs:
      - job_name: 'octocat-supply'
        scrape_interval: 10s
        static_configs:
          - targets: ['octocat-supply.vm.svc.cluster.local:3000']
        metrics_path: '/metrics'
```

```bash
kubectl apply -f promscrape-cm.yaml

# Helm upgrade로 promscrape 마운트
helm upgrade vmsingle vm/victoria-metrics-single --namespace vm \
  --set server.persistentVolume.size=10Gi \
  --set 'server.extraArgs.promscrape\.config=/etc/vm-promscrape/promscrape.yml' \
  --set server.extraVolumes[0].name=promscrape \
  --set server.extraVolumes[0].configMap.name=vm-promscrape \
  --set server.extraVolumeMounts[0].name=promscrape \
  --set server.extraVolumeMounts[0].mountPath=/etc/vm-promscrape
```

---

## 3-7. 24시간 부하 생성

```yaml
# loadgen-24h.yaml
apiVersion: v1
kind: Pod
metadata:
  name: loadgen-24h
  namespace: vm
  labels:
    app: loadgen
spec:
  activeDeadlineSeconds: 86400
  restartPolicy: Never
  containers:
  - name: loadgen
    image: busybox:latest
    command: ["sh", "-c"]
    args:
    - |
      echo "Load generation started at $(date)"
      while true; do
        wget -qO- http://octocat-supply:3000/api/products > /dev/null 2>&1
        wget -qO- http://octocat-supply:3000/api/products/1 > /dev/null 2>&1
        wget -qO- http://octocat-supply:3000/api/orders > /dev/null 2>&1
        wget -qO- http://octocat-supply:3000/api/branches > /dev/null 2>&1
        wget -qO- http://octocat-supply:3000/api/headquarters > /dev/null 2>&1
        wget -qO- http://octocat-supply:3000/api/suppliers > /dev/null 2>&1
        wget -qO- http://octocat-supply:3000/api/deliveries > /dev/null 2>&1
        sleep 1
      done
    resources:
      requests:
        cpu: 50m
        memory: 32Mi
      limits:
        cpu: 100m
        memory: 64Mi
```

```bash
kubectl apply -f loadgen-24h.yaml
```

---

## 3-8. 검증

### Pod 상태 확인

```bash
kubectl get pods -n vm
```

예상 결과:
```
NAME                                        READY   STATUS    AGE
loadgen-24h                                 1/1     Running   26s
octocat-supply-7969bf667c-9htq7             1/1     Running   94s
octocat-supply-7969bf667c-k2ftm             1/1     Running   94s
vmsingle-victoria-metrics-single-server-0   1/1     Running   62s
```

### scrape 상태 확인

```bash
kubectl exec -n vm vmsingle-victoria-metrics-single-server-0 -- \
  wget -qO- http://127.0.0.1:8428/targets
```

예상 결과:
```
job=octocat-supply (1/1 up)
  state=up, endpoint=http://octocat-supply.vm.svc.cluster.local:3000/metrics
  scrapes_total=9, scrapes_failed=0, samples_scraped=161
```

### vmui 접근

```bash
kubectl port-forward -n vm svc/vmsingle-victoria-metrics-single-server 8428:8428
```

브라우저: `http://localhost:8428/vmui`

### 추천 쿼리

```promql
# 경로별 RPS
sum by (path) (rate(http_requests_total{job="octocat-supply"}[5m]))

# P95 응답시간
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))

# Node.js 메모리
process_resident_memory_bytes{job="octocat-supply"}
```

---

## VM vs AKS 비교

| 항목 | VM (Step 2) | AKS (Step 3) |
|------|-------------|--------------|
| 앱 배포 | `npx tsx` 직접 실행 | Docker → Deployment (2 replicas) |
| 이미지 | 로컬 소스 | ACR (`acrvmpoc.azurecr.io`) |
| scrape target | `localhost:3000` | `octocat-supply.vm.svc.cluster.local:3000` |
| promscrape 설정 | `/etc/victoriametrics/promscrape.yml` | ConfigMap → Volume Mount |
| VictoriaMetrics 설정 | systemd ExecStart 옵션 | Helm `extraArgs` + `extraVolumes` |
| vmui 접근 | `http://<IP>:8428/vmui` (NSG 오픈) | `kubectl port-forward` |
| 스케일링 | 수동 프로세스 관리 | `kubectl scale deployment` |
| 부하 생성 | nohup 쉘 스크립트 | Pod (`activeDeadlineSeconds`) |
| 24h 부하 보장 | SSH 끊기면 nohup 의존 | K8s가 Pod lifecycle 관리 |

---

## 작업 이력

| 시간 (UTC) | 작업 |
|------------|------|
| 14:38 | ACR `acrvmpoc` 생성 |
| 14:39 | AKS ↔ ACR 권한 연결 |
| 14:43 | ACR Tasks로 이미지 빌드 (2m28s) |
| 14:43 | VictoriaMetrics Helm 설치 (namespace `vm`) |
| 14:44 | octocat-supply Deployment + Service 배포 |
| 14:44 | promscrape ConfigMap 생성 & Helm upgrade |
| 14:45 | loadgen-24h Pod 생성 (24시간 부하) |
| 14:45 | 검증: targets UP, scrape 성공, 161 samples |

---

## 참고

- [VictoriaMetrics Helm Charts](https://github.com/VictoriaMetrics/helm-charts)
- [AKS + ACR 통합](https://learn.microsoft.com/ko-kr/azure/aks/cluster-container-registry-integration)
- [ACR Tasks (클라우드 빌드)](https://learn.microsoft.com/ko-kr/azure/container-registry/container-registry-tasks-overview)
