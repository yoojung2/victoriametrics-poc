#!/usr/bin/env bash
# VictoriaMetrics single-node 바이너리 설치 스크립트 (Ubuntu amd64)
# 사용: ssh azureuser@<PUBIP> 'bash -s' < scripts/install-vm-binary.sh
set -euo pipefail

# 1) 최신 버전 조회
VM_VERSION=$(curl -s https://api.github.com/repos/VictoriaMetrics/VictoriaMetrics/releases/latest \
  | grep -oP '"tag_name":\s*"\K[^"]+')
echo ">> VictoriaMetrics 버전: ${VM_VERSION}"

# 2) 다운로드 & 설치
cd /tmp
wget -q "https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/${VM_VERSION}/victoria-metrics-linux-amd64-${VM_VERSION}.tar.gz"
tar -xzf "victoria-metrics-linux-amd64-${VM_VERSION}.tar.gz"
sudo mv victoria-metrics-prod /usr/local/bin/victoria-metrics
sudo chmod +x /usr/local/bin/victoria-metrics

# 3) 전용 사용자 & 데이터 디렉터리
sudo useradd -rs /bin/false victoriametrics 2>/dev/null || true
sudo mkdir -p /var/lib/victoria-metrics
sudo chown -R victoriametrics:victoriametrics /var/lib/victoria-metrics

# 4) systemd 유닛 설치
sudo tee /etc/systemd/system/victoriametrics.service > /dev/null <<'UNIT'
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
UNIT

# 5) 서비스 시작
sudo systemctl daemon-reload
sudo systemctl enable --now victoriametrics
sleep 3
sudo systemctl is-active victoriametrics
victoria-metrics --version
echo ">> 설치 완료. http://<PUBIP>:8428/vmui 접속 가능"
