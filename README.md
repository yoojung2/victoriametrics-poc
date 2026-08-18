# VictoriaMetrics PoC 설치 가이드

VictoriaMetrics를 Azure 환경에 설치하는 두 가지 방법을 다룹니다.

| 방식 | 환경 | 용도 |
|------|------|------|
| 바이너리 설치 | Azure VM (Ubuntu 22.04) | 단일 노드, 간단한 테스트/소규모 운영 |
| Helm 설치 | AKS (Kubernetes) | 클러스터 환경, 확장성 필요 시 |

---

## 사전 준비

- Azure CLI 로그인 완료 (`az login`)
- 리소스 그룹 생성

```bash
az group create --name rg-victoriametrics --location koreacentral
```

---

## 1. Azure VM + 바이너리 설치

### 1-1. VM 생성

```bash
az vm create \
  --resource-group rg-victoriametrics \
  --name vm-victoriametrics \
  --image Ubuntu2204 \
  --size Standard_B2s \
  --admin-username azureuser \
  --generate-ssh-keys \
  --public-ip-sku Standard \
  --nsg-rule SSH
```

### 1-2. VM에 SSH 접속

```bash
VM_IP=$(az vm show -d -g rg-victoriametrics -n vm-victoriametrics --query publicIps -o tsv)
ssh azureuser@$VM_IP
```

### 1-3. VictoriaMetrics 바이너리 설치

```bash
# 다운로드 및 설치
cd /tmp
wget https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/v1.108.1/victoria-metrics-linux-amd64-v1.108.1.tar.gz
tar xzf victoria-metrics-linux-amd64-v1.108.1.tar.gz
sudo mv victoria-metrics-prod /usr/local/bin/victoria-metrics

# 서비스 사용자 생성
sudo useradd -r -s /bin/false victoriametrics

# 데이터 디렉토리 생성
sudo mkdir -p /var/lib/victoria-metrics-data
sudo chown victoriametrics:victoriametrics /var/lib/victoria-metrics-data
```

### 1-4. systemd 서비스 등록

```bash
sudo tee /etc/systemd/system/victoriametrics.service <<EOF
[Unit]
Description=VictoriaMetrics
After=network.target

[Service]
User=victoriametrics
ExecStart=/usr/local/bin/victoria-metrics \
  -storageDataPath=/var/lib/victoria-metrics-data \
  -httpListenAddr=:8428 \
  -retentionPeriod=30d
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now victoriametrics
```

### 1-5. 설치 확인

```bash
sudo systemctl status victoriametrics
curl http://localhost:8428/health
# 예상 응답: "OK"
```

### 1-6. (선택) 외부 접근 허용

```bash
az vm open-port \
  --resource-group rg-victoriametrics \
  --name vm-victoriametrics \
  --port 8428 \
  --priority 1010
```

---

## 2. AKS + Helm 설치

### 2-1. AKS 클러스터 생성

```bash
az aks create \
  --resource-group rg-victoriametrics \
  --name aks-victoriametrics \
  --node-count 2 \
  --node-vm-size Standard_B2s \
  --generate-ssh-keys \
  --location koreacentral
```

### 2-2. kubectl 연결

```bash
az aks install-cli  # kubectl/kubelogin 설치 (없는 경우)
az aks get-credentials \
  --resource-group rg-victoriametrics \
  --name aks-victoriametrics

kubectl get nodes  # Ready 상태 확인
```

### 2-3. Helm으로 VictoriaMetrics 설치

```bash
# Helm 설치 (없는 경우)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# VictoriaMetrics Helm 차트 추가
helm repo add vm https://victoriametrics.github.io/helm-charts/
helm repo update

# 설치
helm install vmsingle vm/victoria-metrics-single \
  --namespace vm \
  --create-namespace \
  --set server.persistentVolume.size=10Gi
```

### 2-4. 설치 확인

```bash
kubectl get pods -n vm
# 예상: vmsingle-victoria-metrics-single-server-0  1/1  Running

kubectl get svc -n vm
# 예상: vmsingle-victoria-metrics-single-server  ClusterIP  8428/TCP
```

### 2-5. 포트포워딩으로 접근 테스트

```bash
kubectl port-forward -n vm svc/vmsingle-victoria-metrics-single-server 8428:8428 &
curl http://localhost:8428/health
# 예상 응답: "OK"
```

---

## 데이터 쓰기/읽기 테스트

두 환경 모두 동일한 방법으로 테스트 가능합니다.

```bash
# 메트릭 쓰기 (Prometheus remote write 호환)
curl -d 'test_metric{env="poc"} 123' http://localhost:8428/api/v1/import/prometheus

# 메트릭 읽기
curl 'http://localhost:8428/api/v1/query?query=test_metric'
```

---

## 정리 (리소스 삭제)

```bash
# 전체 리소스 그룹 삭제 (VM + AKS 모두 제거)
az group delete --name rg-victoriametrics --yes --no-wait
```

---

## 참고

- [VictoriaMetrics 공식 문서](https://docs.victoriametrics.com/)
- [Helm Charts 저장소](https://github.com/VictoriaMetrics/helm-charts)
- [GitHub Releases](https://github.com/VictoriaMetrics/VictoriaMetrics/releases)
