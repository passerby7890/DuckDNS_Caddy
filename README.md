🦆 DuckDNS + Caddy 全能反向代理與系統優化腳本

這是一個專為 VPS (虛擬專用服務器) 設計的一鍵部署工具。它不僅能幫你快速建立帶有自動 HTTPS 的反向代理服務，還內建了強大的系統優化功能，特別適合記憶體較小 (512MB/1GB) 的機器使用。

🌟 核心功能

1. 網路服務 (Web Services)

DuckDNS 自動整合：自動配置 DDNS 服務，每 5 分鐘更新一次 IP，無需靜態 IP 也能架站。

Caddy 反向代理：使用 Caddy 2 作為核心，自動申請並續期 Let's Encrypt SSL 證書。

HTTPS 自動化：無需手動配置證書，全程自動化，支援 HSTS 安全傳輸。

路徑重寫：支援將子路徑 (如 /api) 反代到不同的後端服務。

2. 系統極限優化 (System Optimization)

TCP BBR 加速：自動開啟 Google BBR 擁塞控制算法，顯著提升網路吞吐量與穩定性。

智能 Swap 配置：自動檢測並建立物理記憶體 2倍 大小的 Swap (虛擬記憶體)，防止編譯或安裝大型軟體時記憶體不足崩潰。

ZRAM 內存壓縮：啟用 ZRAM 模組，將部分記憶體作為壓縮交換區，提升讀寫效率，讓小記憶體機器跑得更順暢。

防斷線機制：將高風險的網路優化操作移至腳本最後執行，避免 SSH 連線中斷導致安裝失敗。

📋 事前準備

一台 Linux VPS (Ubuntu, Debian, CentOS 均可)。

Root 權限 (或是使用 sudo)。

DuckDNS 帳號：

前往 duckdns.org 使用 Google 或 GitHub 登入。

創建一個 Domain (例如 mysite)。

複製頁面上方的 Token。

🚀 快速開始

1. 下載並運行腳本

您可以直接從 GitHub 下載最新版本的腳本並執行：

# 下載腳本
wget -O deploy-duckdns.sh https://raw.githubusercontent.com/passerby7890/DuckDNS_Caddy/refs/heads/main/deploy-duckdns.sh

# 給予執行權限
chmod +x deploy-duckdns.sh

# 執行腳本
./deploy-duckdns.sh


腳本原始碼地址：GitHub - DuckDNS_Caddy/deploy-duckdns.sh

2. 互動式配置

腳本執行過程中會詢問以下資訊：

DuckDNS 子域名：輸入你在 DuckDNS 申請的名稱 (例如輸入 mysite 代表 mysite.duckdns.org)。

DuckDNS Token：貼上從網站複製的 Token。

目標 URL：你想要反代的後端服務地址 (例如 http://127.0.0.1:8080)。

路徑設定：可以設定是否要加上路徑前綴 (Prefix)，或更改本地訪問路徑。

🛠️ 管理指令

腳本執行完畢後，會在你的家目錄下生成一個專案資料夾 (例如 ~/duckdns-proxy-mysite)，裡面包含以下管理工具：

啟動與停止

cd ~/duckdns-proxy-mysite

# 啟動服務
./start.sh

# 停止服務
./stop.sh

# 重啟服務 (先 stop 再 start)
./stop.sh && ./start.sh


查看狀態

# 查看即時日誌 (按 Ctrl+C 退出)
./logs.sh

# 檢查 SSL 證書狀態與到期日
./check-cert.sh


📂 目錄結構

~/duckdns-proxy-{你的域名}/
├── Caddyfile              # Caddy 的核心配置文件
├── docker-compose.yml     # Docker 容器編排文件
├── duckdns-config.env     # 環境變數與配置備份
├── start.sh               # 啟動腳本
├── stop.sh                # 停止腳本
├── logs.sh                # 日誌查看腳本
└── check-cert.sh          # 證書檢查工具


❓ 常見問題 (Q&A)

Q: 安裝過程中 SSH 斷線了怎麼辦？
A: 腳本 v6 版本已經優化了順序，將導致網路瞬斷的 BBR 優化移到了最後一步。如果最後一步斷線，通常服務已經部署成功，重新連線即可。

Q: 證書如何續期？
A: Caddy 會在證書到期前 30 天自動續期，完全無需人工干預。只要你的 Docker 容器在運行且 80 端口開放，證書就會自動更新。

Q: 我可以修改 Caddyfile 嗎？
A: 可以。修改 Caddyfile 後，請執行 ./stop.sh 然後 ./start.sh 重啟容器以套用變更。

Q: 為什麼我的記憶體佔用變高了？
A: 這是正常的。因為我們開啟了 ZRAM，Linux 會更積極地使用記憶體來緩存數據以提升效能，這不是記憶體洩漏。

⚠️ 注意事項

請確保您的雲服務商防火牆 (Security Group) 已放行 TCP 80 和 TCP 443 端口。

本腳本會自動安裝 Docker (如果未安裝)。

請勿手動刪除生成的 Swap 文件，否則可能會導致系統不穩定。
