# Step 3 — AKS에서 전체 파이프라인 재현 (앱 + vmagent + loadgen)

> 📚 [← 전체 개요(README)](../README.md) · [Step 1: 설치](step1-install.md) · [Step 2: 앱 메트릭 연동](step2-app-metrics.md) · **Step 3: AKS 이전**

Step 2에서 **VM(바이너리)** 위에 구성한 파이프라인(octocat API 계측 → vmagent → VictoriaMetrics → 쿼리)을,
**AKS(Kubernetes)** 위에서 동일하게 재현합니다. VM 환경은 **그대로 유지**하고 AKS에 병렬로 올립니다.

## 전체 구조

```
                     namespace: vm  (Step 1에서 vmsingle 이미 설치됨)
  ┌───────────────────────────────────────────────────────────────┐
  │  [loadgen Deployment] ──HTTP 24h──▶ [octocat-api Service :3000] │
  │                                          │ /metrics            │
  │                                          ▼                     │
  │                         [vmagent Deployment] ──remote_write──▶ │
  │                                          [vmsingle :8428] ◀── vmui/port-forward 쿼리
  └───────────────────────────────────────────────────────────────┘
```

## 주요 구성 컴포넌트

| 컴포넌트 | 종류 | 역할 | 매니페스트 |
|----------|------|------|-----------|
| **octocat-api** | Deployment + Service | prom-client 계측 앱, `/metrics` 노출 (Service `:3000`) | [step3/k8s/01-octocat-api.yaml](../step3/k8s/01-octocat-api.yaml) |
| **vmagent** | Deployment + ConfigMap | 앱 Service 스크레이프 → vmsingle로 `remote_write` | [step3/k8s/02-vmagent.yaml](../step3/k8s/02-vmagent.yaml) |
| **loadgen** | Deployment | 클러스터 내부에서 앱에 **24시간 지속 부하** | [step3/k8s/03-loadgen.yaml](../step3/k8s/03-loadgen.yaml) |
| **vmsingle** | (Step 1 Helm) | 메트릭 저장/쿼리 (`vm` namespace, 재사용) | Step 1 |
| **ACR** | Azure 리소스 | 계측된 앱 이미지 빌드/저장 | 아래 1단계 |

> VM 방식과의 차이: VM은 로컬 프로세스로 실행했지만, AKS는 **이미지 빌드(ACR) → 매니페스트 배포**가 필요합니다. loadgen도 로컬 스크립트가 아니라 **클러스터 내 Deployment**라서, 로컬 세션이 꺼져도 24시간 부하가 유지됩니다.

---

## 사전 상태 (Step 1 재사용)

```bash
az aks get-credentials -g rg-victoriametrics-poc -n aks-victoriametrics --overwrite-existing
kubectl get pods,svc -n vm
# -> vmsingle-victoria-metrics-single-server-0  Running
#    svc/vmsingle-victoria-metrics-single-server  ClusterIP  8428/TCP
```

---

## 1. ACR 생성 + AKS 연결 + 이미지 빌드

로컬에 Docker가 없어도 `az acr build`가 **클라우드에서 이미지를 빌드**합니다.

```bash
export RG=rg-victoriametrics-poc
export AKS=aks-victoriametrics
export ACR=vmpocacr64419          # 전역 고유 이름

# ACR 생성 (완료됨: vmpocacr64419.azurecr.io)
az acr create -g "$RG" -n "$ACR" --sku Basic -o table

# AKS 노드가 ACR에서 pull 할 수 있도록 연결 (kubelet identity에 AcrPull 부여)
az aks update -g "$RG" -n "$AKS" --attach-acr "$ACR"

# prom-client 계측이 포함된 octocat api 이미지를 클라우드 빌드
#   ※ Step 2에서 api/src/metrics-middleware.ts + index.ts 수정본이 포함된 소스를 사용
az acr build -r "$ACR" -t octocat-api:metrics ./octocat-supply/api
```

> ✅ **실측 완료:** ACR `vmpocacr64419` 생성 → `--attach-acr`(AcrPull 부여) → `az acr build`로 이미지 빌드/푸시까지 모두 실행 검증됨. 이미지: `vmpocacr64419.azurecr.io/octocat-api:metrics` (digest `sha256:68a889…`).

이미지 빌드 후, 매니페스트의 이미지 경로를 치환:
```bash
export LOGINSERVER=$(az acr show -n "$ACR" -g "$RG" --query loginServer -o tsv)
sed -i "s#REPLACE_WITH_ACR_LOGINSERVER#${LOGINSERVER}#" step3/k8s/01-octocat-api.yaml
```

---

## 2. 앱 배포 (Deployment + Service)

```bash
kubectl apply -f step3/k8s/01-octocat-api.yaml
kubectl -n vm rollout status deploy/octocat-api
# /metrics 확인 (클러스터 내부)
kubectl -n vm run curltest --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://octocat-api.vm.svc.cluster.local:3000/metrics
# -> 200
```

## 3. vmagent 배포 (scrape → remote_write)

```bash
kubectl apply -f step3/k8s/02-vmagent.yaml
kubectl -n vm logs deploy/vmagent | grep -i "added targets"
# -> static_configs: added targets: 1
```

remoteWrite 대상은 Step 1의 vmsingle Service:
```
http://vmsingle-victoria-metrics-single-server.vm.svc.cluster.local:8428/api/v1/write
```

## 4. loadgen 배포 (24시간 지속 부하)

```bash
kubectl apply -f step3/k8s/03-loadgen.yaml
kubectl -n vm logs deploy/loadgen --tail=5
# -> >> loadgen 시작: http://octocat-api...:3000 (86400s)
```

- `DURATION=86400`(24h). **로컬 세션과 무관하게** 클러스터에서 계속 실행됩니다.
- 중단하려면:
  ```bash
  kubectl -n vm scale deploy/loadgen --replicas=0   # 일시정지
  kubectl -n vm delete -f step3/k8s/03-loadgen.yaml # 완전 제거
  ```

## 5. 쿼리 검증 (vmsingle) — ✅ 실측 완료

```bash
kubectl -n vm port-forward svc/vmsingle-victoria-metrics-single-server 8428:8428
# 브라우저: http://localhost:8428/vmui
```

vmui 쿼리 (Step 2와 동일, `env="poc-aks"` 라벨로 VM 데이터와 구분 가능):
```promql
sum by (status) (rate(http_requests_total{env="poc-aks"}[1m]))
histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{env="poc-aks"}[5m])))
```

**실측 결과** (loadgen Deployment 가동 중, vmsingle에서 직접 조회):

| 쿼리 | 결과 |
|------|------|
| `sum(rate(http_requests_total{env="poc-aks"}[1m]))` | **17.7 req/s** |
| status=200 RPS | 15.2 req/s |
| status=404 RPS | 2.5 req/s (`/nonexistent`) |
| 시리즈 수 | 3 |

배포 결과(namespace `vm`):
```
octocat-api  Deployment+Service   image: vmpocacr64419.azurecr.io/octocat-api:metrics, /metrics=200
vmagent      Deployment+ConfigMap  static_configs: added targets: 1, remote_write→vmsingle
loadgen      Deployment            DURATION=86400(24h) 실행 중 (세션 독립)
vmsingle     (Step 1 Helm)         저장/쿼리
```

---

## VM 방식 vs AKS 방식 요약

| 항목 | VM (Step 2) | AKS (Step 3) |
|------|-------------|--------------|
| 앱 실행 | 로컬 `npm run dev` | Deployment (ACR 이미지) |
| vmagent | 바이너리 프로세스 | Deployment + ConfigMap |
| remote_write 대상 | VM Public IP `:8428` | vmsingle Service DNS |
| 부하 | 로컬 `loadgen.sh` (세션 종속) | loadgen Deployment (24h, 세션 독립) |
| 저장소 | VM systemd VictoriaMetrics | Step 1 Helm vmsingle |
| 외부 노출 | NSG 8428 오픈 | port-forward (기본 ClusterIP) |

---

## 이 단계에서 만든 파일

```
step3/
└── k8s/
    ├── 01-octocat-api.yaml   # 앱 Deployment + Service (/metrics)
    ├── 02-vmagent.yaml       # vmagent Deployment + scrape ConfigMap
    └── 03-loadgen.yaml       # 24시간 부하 Deployment
```

## 정리(삭제)

```bash
kubectl -n vm delete -f step3/k8s/          # 앱+vmagent+loadgen 제거 (vmsingle은 유지)
az acr delete -n vmpocacr64419 -g rg-victoriametrics-poc --yes   # ACR 제거
```
