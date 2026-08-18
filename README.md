# VictoriaMetrics PoC — Azure VM(바이너리) & AKS(Helm) 설치 가이드

Azure 환경에서 **VictoriaMetrics(single-node)** 를 두 가지 방식으로 설치·검증한 PoC 저장소입니다.

| 방식 | 대상 | 설치 방법 |
|------|------|-----------|
| **① 바이너리 + systemd** | Azure VM (Ubuntu 22.04) | GitHub 릴리스 바이너리 |
| **② Helm** | AKS (Kubernetes) | `victoria-metrics-single` 차트 |

> 검증 환경: 구독 `ME-MngEnvMCAP663093-yoojunglee-2`, 리전 `koreacentral`, VictoriaMetrics `v1.150.0`

---

## 목차
- [사전 준비](#사전-준비)
- [공통 변수](#공통-변수)
- [① Azure VM + 바이너리 설치](#-azure-vm--바이너리-설치)
- [② AKS + Helm 설치](#-aks--helm-설치)
- [동작 검증](#동작-검증)
- [정리(리소스 삭제)](#정리리소스-삭제)
- [트러블슈팅](#트러블슈팅)

---

## 사전 준비

| 도구 | 확인 명령 |
|------|-----------|
| Azure CLI | `az version` |
| kubectl | `kubectl version --client` |
| helm | `helm version` |
| 로그인 | `az login` / `az account show` |

```bash
# 구독 선택 (필요 시)
az account set --subscription "<SUBSCRIPTION_ID>"
```

---

## 공통 변수

```bash
export RG="rg-victoriametrics-poc"
export LOC="koreacentral"

# Resource Group 생성
az group create --name "$RG" --location "$LOC" -o table
```

---

## ① Azure VM + 바이너리 설치

### 1-1. VM 생성

```bash
export VM="vm-victoriametrics"

az vm create \
  --resource-group "$RG" \
  --name "$VM" \
  --image Ubuntu2204 \
  --size Standard_B2s \
  --admin-username azureuser \
  --generate-ssh-keys \
  --public-ip-sku Standard \
  --os-disk-size-gb 32

# VictoriaMetrics UI/API 포트(8428) 오픈
az vm open-port --resource-group "$RG" --name "$VM" --port 8428 --priority 1010

# Public IP 확인
export PUBIP=$(az vm show -d -g "$RG" -n "$VM" --query publicIps -o tsv)
echo "Public IP: $PUBIP"
```

### 1-2. 바이너리 설치 (SSH 접속 후)

`scripts/install-vm-binary.sh` 를 VM에서 실행하거나 아래를 그대로 수행합니다.

```bash
ssh azureuser@$PUBIP 'bash -s' < scripts/install-vm-binary.sh
```

스크립트 핵심 내용:

```bash
# 최신 버전 조회 & 다운로드
VM_VERSION=$(curl -s https://api.github.com/repos/VictoriaMetrics/VictoriaMetrics/releases/latest \
  | grep -oP '"tag_name":\s*"\K[^"]+')
cd /tmp
wget -q https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/${VM_VERSION}/victoria-metrics-linux-amd64-${VM_VERSION}.tar.gz
tar -xzf victoria-metrics-linux-amd64-${VM_VERSION}.tar.gz
sudo mv victoria-metrics-prod /usr/local/bin/victoria-metrics
sudo chmod +x /usr/local/bin/victoria-metrics

# 전용 사용자 & 데이터 디렉터리
sudo useradd -rs /bin/false victoriametrics 2>/dev/null || true
sudo mkdir -p /var/lib/victoria-metrics
sudo chown -R victoriametrics:victoriametrics /var/lib/victoria-metrics
```

### 1-3. systemd 서비스 등록

`systemd/victoriametrics.service` 를 `/etc/systemd/system/` 에 배치합니다.

```ini
[Unit]
Description=VictoriaMetrics single-node
After=network.target

[Service]
Type=simple
User=victoriametrics
Group=victoriametrics
ExecStart=/usr/local/bin/victoria-metrics --storageDataPath=/var/lib/victoria-metrics --httpListenAddr=:8428 --retentionPeriod=12
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now victoriametrics
sudo systemctl is-active victoriametrics   # -> active
```

| 옵션 | 설명 |
|------|------|
| `--storageDataPath` | 데이터 저장 경로 |
| `--httpListenAddr` | HTTP API/UI 리슨 주소 (기본 `:8428`) |
| `--retentionPeriod` | 데이터 보존 기간 (`12`=12개월, `30d`, `1w` 등) |

### 1-4. 접속

- vmui: `http://<PUBIP>:8428/vmui`
- Health: `http://<PUBIP>:8428/health`

---

## ② AKS + Helm 설치

### 2-1. AKS 클러스터 생성

```bash
export AKS="aks-victoriametrics"

az aks create \
  --resource-group "$RG" \
  --name "$AKS" \
  --node-count 2 \
  --node-vm-size Standard_B2s \
  --generate-ssh-keys

# kubeconfig 병합
az aks get-credentials --resource-group "$RG" --name "$AKS" --overwrite-existing
kubectl get nodes
```

### 2-2. Helm 차트 설치

```bash
helm repo add vm https://victoriametrics.github.io/helm-charts/
helm repo update

helm install vmsingle vm/victoria-metrics-single \
  --namespace vm --create-namespace \
  --set server.persistentVolume.enabled=true \
  --set server.persistentVolume.size=10Gi

# Pod Ready 대기
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/instance=vmsingle -n vm --timeout=120s
kubectl get pods,svc -n vm
```

### 2-3. 접속 (port-forward)

```bash
export POD_NAME=$(kubectl get pods -n vm \
  -l app.kubernetes.io/component=server \
  -l app.kubernetes.io/instance=vmsingle \
  -o jsonpath="{.items[0].metadata.name}")
kubectl -n vm port-forward $POD_NAME 8428
# 이후 http://localhost:8428/vmui 접속
```

클러스터 내부 write/read 엔드포인트:

```
http://vmsingle-victoria-metrics-single-server.vm.svc.cluster.local:8428
```

---

## 동작 검증

두 환경 공통으로 아래 방식으로 검증합니다. (`$BASE` = VM은 `http://$PUBIP:8428`, AKS는 port-forward 후 `http://localhost:8428`)

```bash
# 1) 헬스체크
curl -s $BASE/health          # -> OK

# 2) 메트릭 쓰기 (Prometheus 포맷)
curl -s -d 'demo_metric{env="test"} 42' \
  "$BASE/api/v1/import/prometheus" -w "write=%{http_code}\n"   # -> 204

# 3) 저장 확인 (export)
curl -s "$BASE/api/v1/export" -d 'match[]=demo_metric'

# 4) 전체 메트릭명
curl -s "$BASE/api/v1/label/__name__/values"
```

**검증 결과(PoC):**

| 환경 | health | write | export |
|------|--------|-------|--------|
| Azure VM (바이너리) | `OK` | `204` | `test_metric`, `demo_local_metric` 저장 확인 ✓ |
| AKS (Helm) | `OK` | `204` | `aks_demo_metric` 저장 확인 ✓ |

> 참고: `import/prometheus` 로 타임스탬프 없이 넣은 샘플은 instant query(`/api/v1/query`)에서 시간창에 따라 빈 결과가 나올 수 있습니다. 저장 여부는 `/api/v1/export` 로 확인하는 것이 확실합니다.

---

## 정리(리소스 삭제)

```bash
# Helm 릴리스만 제거
helm uninstall vmsingle -n vm

# 전체 리소스 그룹 삭제 (VM + AKS + 네트워크 일괄)
az group delete --name "$RG" --yes --no-wait
```

---

## 트러블슈팅

| 증상 | 원인/해결 |
|------|-----------|
| 외부에서 `:8428` 접속 불가 | `az vm open-port ... --port 8428` 확인, NSG 규칙 점검 |
| `systemctl status` 에서 실패 | `journalctl -u victoriametrics -e` 로 로그 확인, `storageDataPath` 권한 확인 |
| instant query 결과 비어있음 | `import/prometheus` 샘플은 `export` 로 저장 확인 (위 참고) |
| AKS Pod `Pending` | PVC/노드 리소스 확인: `kubectl describe pod -n vm <pod>` |

---

## 디렉터리 구조

```
victoriametrics-poc/
├── README.md
├── scripts/
│   └── install-vm-binary.sh     # VM 바이너리 설치 스크립트
└── systemd/
    └── victoriametrics.service  # systemd 유닛 파일
```
