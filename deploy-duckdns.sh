#!/bin/bash
# deploy-duckdns.sh
# DuckDNS + Caddy 反向代理自動部署腳本 (v6: 順序優化版)
# 功能：智能Swap / DDNS / SSL / 反代 / 證書監控 / (最後執行: BBR加速 + ZRAM)
# 修復：解決 BBR 導致的 SSH 殭屍連線與輸入後崩潰問題

set -e

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🦆 DuckDNS 反向代理部署 (v6: 順序優化版)${NC}"
echo "================================================"

# ----------------------------------------------------------------
# 0. 基礎系統準備 (只處理 Swap，避免斷線)
# ----------------------------------------------------------------
prepare_system() {
    echo -e "${BLUE}🧠 系統基礎準備...${NC}"

    # --- 設置 Swap (智能防崩潰) ---
    echo -n "   檢查 Swap 設置... "
    
    # 檢查是否已存在任何 swap
    if [ $(swapon --show --noheadings | wc -l) -gt 0 ]; then
        CURRENT_SWAP=$(free -m | awk '/Swap:/ {print $2}')
        echo -e "${GREEN}已存在 Swap (${CURRENT_SWAP}MB)，跳過。${NC}"
    else
        # 只有在完全沒有 Swap 時才創建
        PHY_MEM_MB=$(free -m | awk '/Mem:/ {print $2}')
        TARGET_SWAP_MB=$((PHY_MEM_MB * 2))
        if [ $TARGET_SWAP_MB -gt 4096 ]; then TARGET_SWAP_MB=4096; fi
        
        echo -e "${YELLOW}創建 Swap (${TARGET_SWAP_MB}MB) 以保護安裝過程...${NC}"
        fallocate -l ${TARGET_SWAP_MB}M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=${TARGET_SWAP_MB} >/dev/null 2>&1
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1
        swapon /swapfile
        
        if ! grep -q "/swapfile" /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        echo -e "${GREEN}   ✅ Swap 創建成功${NC}"
    fi
    # 強制同步磁碟，避免 IO 延遲
    sync
    echo ""
}

# 執行基礎準備
prepare_system

# ----------------------------------------------------------------
# 1. DuckDNS 配置互動
# ----------------------------------------------------------------
echo -e "${YELLOW}⚙️  DuckDNS 帳戶配置${NC}"
echo "請先前往 https://www.duckdns.org 獲取您的域名和 Token"
echo "-------------------"

read -p "請輸入您的 DuckDNS 子域名 (例如輸入 'mysite' 代表 'mysite.duckdns.org'): " DUCK_SUBDOMAIN
if [ -z "$DUCK_SUBDOMAIN" ]; then
    echo -e "${RED}❌ 子域名不能為空${NC}"
    exit 1
fi
# 移除可能輸入的 .duckdns.org 後綴
DUCK_SUBDOMAIN=${DUCK_SUBDOMAIN%%.duckdns.org}
FULL_DOMAIN="${DUCK_SUBDOMAIN}.duckdns.org"

read -p "請輸入您的 DuckDNS Token (從網站上方複製): " DUCK_TOKEN
if [ -z "$DUCK_TOKEN" ]; then
    echo -e "${RED}❌ Token 不能為空${NC}"
    exit 1
fi

# 測試 Token 有效性並立即更新一次 IP (增加超時設定防止卡死)
echo -e "${BLUE}🔄 正在測試 Token 並更新 DuckDNS IP...${NC}"
UPDATE_RESULT=$(curl -s --max-time 10 "https://www.duckdns.org/update?domains=${DUCK_SUBDOMAIN}&token=${DUCK_TOKEN}&ip=")

if [[ "$UPDATE_RESULT" == *"OK"* ]]; then
    echo -e "${GREEN}✅ DuckDNS 更新成功！域名: ${FULL_DOMAIN}${NC}"
else
    echo -e "${RED}❌ DuckDNS 更新失敗，請檢查 Token 或子域名是否正確。${NC}"
    echo "DuckDNS 回傳: $UPDATE_RESULT"
    exit 1
fi
echo ""

# ----------------------------------------------------------------
# 2. 詢問反代目標配置
# ----------------------------------------------------------------
echo -e "${YELLOW}🎯 配置反向代理目標${NC}"
read -p "請輸入要反代的目标URL（例如: http://127.0.0.1:8080 或 https://example.com）: " TARGET_INPUT
if [ -z "$TARGET_INPUT" ]; then
    echo -e "${RED}⚠️  使用默認演示值: https://www.google.com${NC}"
    TARGET_INPUT="https://www.google.com"
fi
# 確保有協議頭
if [[ ! "$TARGET_INPUT" =~ ^https?:// ]]; then TARGET_INPUT="http://$TARGET_INPUT"; fi

# 處理 URL
TARGET_PROTO=$(echo "$TARGET_INPUT" | sed -E 's|^(https?)://.*|\1|')
TARGET_HOST_PORT=$(echo "$TARGET_INPUT" | sed -E 's|^https?://||' | cut -d'/' -f1)
TARGET_UPSTREAM="${TARGET_PROTO}://${TARGET_HOST_PORT}"
TARGET_DOMAIN=$(echo "$TARGET_HOST_PORT" | cut -d':' -f1)

echo -e "   解析上游地址: ${TARGET_UPSTREAM}"

read -p "請輸入要反代的目標路徑前綴（例如: /api，留空為不添加）: " TARGET_PATH_PREFIX
TARGET_PATH_PREFIX=$(echo "$TARGET_PATH_PREFIX" | sed 's|^/||' | sed 's|/$||')
if [ -n "$TARGET_PATH_PREFIX" ]; then
    TARGET_PATH_PREFIX="/${TARGET_PATH_PREFIX}"
fi

read -p "請輸入本地訪問路徑（例如: /app/，留空為根路徑 /）: " LOCAL_PATH
if [ -z "$LOCAL_PATH" ]; then LOCAL_PATH="/"; fi
if [[ ! "$LOCAL_PATH" =~ ^/ ]]; then LOCAL_PATH="/$LOCAL_PATH"; fi
if [ "$LOCAL_PATH" != "/" ] && [[ ! "$LOCAL_PATH" =~ /$ ]]; then LOCAL_PATH="${LOCAL_PATH}/"; fi

# ----------------------------------------------------------------
# 3. 檢查 Docker (增加鎖檢查)
# ----------------------------------------------------------------
if ! command -v docker &> /dev/null; then
    echo "📦 準備安裝 Docker..."
    
    # 等待 apt/yum 鎖釋放
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || fuser /var/run/yum.pid >/dev/null 2>&1; do
        echo "   ⏳ 等待系統更新鎖釋放..."
        sleep 5
    done

    curl -fsSL https://get.docker.com | sh
    systemctl start docker
    systemctl enable docker
fi

# ----------------------------------------------------------------
# 4. 暴力清理端口
# ----------------------------------------------------------------
echo -e "${BLUE}🧹 正在暴力清理 80 和 443 端口...${NC}"
systemctl stop nginx 2>/dev/null || true
systemctl stop apache2 2>/dev/null || true
if command -v fuser &> /dev/null; then
    fuser -k 80/tcp 2>/dev/null || true
    fuser -k 443/tcp 2>/dev/null || true
fi
if netstat -tulpn | grep -E ':80\s|:443\s' &> /dev/null; then
    echo -e "${RED}⚠️  警告: 端口似乎仍被佔用，請手動檢查 'netstat -tulpn'${NC}"
else
    echo -e "${GREEN}✅ 端口已清理${NC}"
fi

# ----------------------------------------------------------------
# 5. 創建目錄與配置 (自動清理舊配置)
# ----------------------------------------------------------------
PROJECT_NAME="duckdns-proxy-${DUCK_SUBDOMAIN}"
PROJECT_DIR="$HOME/$PROJECT_NAME"

echo -e "${BLUE}♻️  檢查並清理舊配置...${NC}"
if [ -d "$PROJECT_DIR" ]; then
    if [ -f "$PROJECT_DIR/docker-compose.yml" ]; then
        cd "$PROJECT_DIR"
        if docker compose version >/dev/null 2>&1; then
            docker compose down >/dev/null 2>&1 || true
        else
            docker-compose down >/dev/null 2>&1 || true
        fi
        cd ..
    fi
    rm -rf "$PROJECT_DIR"
fi

if docker ps -a --format '{{.Names}}' | grep -q "^${PROJECT_NAME}$"; then
    docker rm -f "${PROJECT_NAME}" >/dev/null 2>&1 || true
fi

echo -e "${BLUE}📁 創建新項目目錄: $PROJECT_DIR${NC}"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# 保存配置
cat > duckdns-config.env << EOF
DUCK_SUBDOMAIN=$DUCK_SUBDOMAIN
FULL_DOMAIN=$FULL_DOMAIN
TARGET_UPSTREAM=$TARGET_UPSTREAM
TARGET_PATH_PREFIX=$TARGET_PATH_PREFIX
LOCAL_PATH=$LOCAL_PATH
CREATED_AT=$(date +"%Y-%m-%d %H:%M:%S")
EOF

# 創建 Caddyfile
cat > Caddyfile << EOF
{
    email admin@${FULL_DOMAIN}
    # 禁用 HTTP/3 (QUIC)
    servers {
        protocols h1 h2
    }
}

http://${FULL_DOMAIN} {
    redir https://{host}{uri} permanent
}

${FULL_DOMAIN} {
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
    }
EOF

if [ "$LOCAL_PATH" = "/" ]; then
    cat >> Caddyfile << EOF
    
    $(if [ -n "$TARGET_PATH_PREFIX" ]; then echo "rewrite * ${TARGET_PATH_PREFIX}{uri}"; fi)

    reverse_proxy ${TARGET_UPSTREAM} {
        header_up Host ${TARGET_DOMAIN}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
EOF
else
    cat >> Caddyfile << EOF
    
    handle_path ${LOCAL_PATH}* {
        $(if [ -n "$TARGET_PATH_PREFIX" ]; then echo "rewrite * ${TARGET_PATH_PREFIX}{uri}"; fi)

        reverse_proxy ${TARGET_UPSTREAM} {
            header_up Host ${TARGET_DOMAIN}
            header_up X-Real-IP {remote_host}
        }
    }

    handle {
        respond "✅ DuckDNS Proxy Active. Please visit ${LOCAL_PATH}" 200
    }
}
EOF
fi

# 創建 docker-compose.yml
cat > docker-compose.yml << EOF
services:
  caddy:
    image: caddy:2-alpine
    container_name: ${PROJECT_NAME}
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - proxy-net
    depends_on:
      - ddns

  ddns:
    image: lscr.io/linuxserver/duckdns:latest
    container_name: ${PROJECT_NAME}-ddns
    restart: unless-stopped
    environment:
      - SUBDOMAINS=${DUCK_SUBDOMAIN}
      - TOKEN=${DUCK_TOKEN}
      - LOG_FILE=false
    networks:
      - proxy-net

networks:
  proxy-net:
    driver: bridge

volumes:
  caddy_data:
  caddy_config:
EOF

# 創建管理腳本
echo "docker compose up -d" > start.sh && chmod +x start.sh
echo "docker compose logs -f" > logs.sh && chmod +x logs.sh
echo "docker compose down" > stop.sh && chmod +x stop.sh

# 創建證書檢查腳本
cat > check-cert.sh << 'EOF'
#!/bin/bash
if [ -f duckdns-config.env ]; then
    source duckdns-config.env
    echo "🔐 檢查 SSL 證書狀態: https://$FULL_DOMAIN"
    echo "==================================================="
    if ! command -v openssl &> /dev/null; then
        echo "⚠️  系統未安裝 openssl，嘗試使用 docker 內部檢查..."
        CONTAINER_NAME="duckdns-proxy-${DUCK_SUBDOMAIN}"
        docker exec $CONTAINER_NAME caddy list-certs
    else
        echo | openssl s_client -servername $FULL_DOMAIN -connect 127.0.0.1:443 2>/dev/null | openssl x509 -noout -dates -issuer -subject
    fi
    echo "==================================================="
    echo "✅ 只要此服務保持運行，證書將自動續期。"
else
    echo "❌ 找不到配置文件"
fi
EOF
chmod +x check-cert.sh

# ----------------------------------------------------------------
# 6. 啟動服務
# ----------------------------------------------------------------
echo -e "${GREEN}🚀 啟動服務...${NC}"

if docker compose version >/dev/null 2>&1; then
    docker compose up -d
else
    if ! command -v docker-compose &> /dev/null; then
         curl -L "https://github.com/docker/compose/releases/download/v2.20.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
         chmod +x /usr/local/bin/docker-compose
    fi
    docker-compose up -d
fi

echo -e "${BLUE}⏳ 等待 5 秒檢查容器狀態...${NC}"
sleep 5

CONTAINER_STATUS=$(docker ps --filter "name=${PROJECT_NAME}" --format "{{.Status}}")
if [[ "$CONTAINER_STATUS" == *"Up"* ]]; then
    echo ""
    echo -e "${GREEN}✅ 部署成功！容器運行中。${NC}"
    echo -e "🔗 訪問地址: ${GREEN}https://${FULL_DOMAIN}${LOCAL_PATH}${NC}"
else
    echo ""
    echo -e "${RED}❌ 部署後容器未運行！${NC}"
    docker compose logs --tail=20
    # 如果容器失敗，不繼續執行優化
    exit 1
fi

# ----------------------------------------------------------------
# 7. 最後執行：風險較高的網路優化 (BBR & ZRAM)
# ----------------------------------------------------------------
echo ""
echo -e "${BLUE}🚀 服務已啟動，開始進行網路優化 (BBR/ZRAM)...${NC}"
echo "⚠️  注意：如果 SSH 在此處斷線，請不用擔心，服務已經部署成功。"

# --- 啟用 TCP BBR ---
echo -n "   [1/2] 檢查 TCP BBR... "
if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
    echo -e "${GREEN}已啟用${NC}"
else
    echo "正在啟用 (可能會導致 SSH 瞬斷)..."
    cp /etc/sysctl.conf /etc/sysctl.conf.bak
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    # 這裡是最容易斷線的地方，使用 || true 確保腳本邏輯不報錯
    sysctl -p > /dev/null 2>&1 || true
    echo -e "${GREEN}   ✅ TCP BBR 已開啟${NC}"
fi

# --- 啟用 ZRAM ---
echo -n "   [2/2] 配置 ZRAM (內存壓縮)... "
if lsmod | grep -q zram; then
    echo -e "${GREEN}ZRAM 已載入${NC}"
else
    if modprobe zram; then
        cat > /etc/systemd/system/zram-config.service << EOF
[Unit]
Description=Configure ZRAM for memory compression
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'modprobe zram && echo lz4 > /sys/block/zram0/comp_algorithm && echo \$(( \$(grep MemTotal /proc/meminfo | awk "{print \$2}") * 1024 / 2 )) > /sys/block/zram0/disksize && mkswap /sys/block/zram0 && swapon /sys/block/zram0 -p 100'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now zram-config.service >/dev/null 2>&1
        echo -e "${GREEN}   ✅ ZRAM 服務已安裝${NC}"
    else
        echo -e "${RED}❌ 系統內核缺少 ZRAM 模組，跳過${NC}"
    fi
fi

echo ""
echo -e "${GREEN}🎉 全部完成！您的伺服器現在已經武裝到牙齒了。${NC}"
