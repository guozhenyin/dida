#!/bin/sh

# 解决 Alpine 默认没有 bash 的问题
if [ -z "$BASH_VERSION" ]; then
    apk update >/dev/null 2>&1
    apk add --no-cache bash curl wget tar jq openssl ca-certificates gcompat coreutils >/dev/null 2>&1
    exec /bin/bash "$0" "$@"
fi

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

CONFIG_FILE="/etc/sing-box/config.json"
INFO_FILE="/etc/sing-box/install_info"
SERVICE_NAME="sing-box"

#############################################
# 工具函数
#############################################
print_client_config() {
    if [ ! -f "$INFO_FILE" ]; then
        echo -e "${RED}未找到安装信息，请先安装${NC}"
        return 1
    fi

    source "$INFO_FILE"

    echo
    echo -e "${GREEN}======================================================${NC}"
    echo -e "${GREEN}              当前客户端配置信息${NC}"
    echo -e "${GREEN}======================================================${NC}"
    echo
    echo -e "${CYAN}服务器 IP     : ${SERVER_IP}${NC}"
    echo -e "${CYAN}伪装域名      : ${SNI}${NC}"
    echo -e "${CYAN}VLESS 端口    : ${PORT_VLESS}${NC}"
    echo -e "${CYAN}Hysteria2 端口: ${PORT_HY2}${NC}"
    echo -e "${CYAN}SOCKS5 端口   : ${PORT_SOCKS}${NC}"
    echo

    echo -e "${BLUE}---------- VLESS + Reality ----------${NC}"
    cat << CLIENT
{
  "type": "vless",
  "tag": "reality",
  "server": "${SERVER_IP}",
  "server_port": ${PORT_VLESS},
  "uuid": "${UUID}",
  "flow": "xtls-rprx-vision",
  "tls": {
    "enabled": true,
    "server_name": "${SNI}",
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    },
    "reality": {
      "enabled": true,
      "public_key": "${PUBLIC_KEY}",
      "short_id": "${SHORT_ID}"
    }
  }
}
CLIENT
    echo

    echo -e "${BLUE}---------- Hysteria2 ----------${NC}"
    cat << CLIENT
{
  "type": "hysteria2",
  "tag": "hy2",
  "server": "${SERVER_IP}",
  "server_port": ${PORT_HY2},
  "password": "${HY2_PASSWORD}",
  "tls": {
    "enabled": true,
    "server_name": "${SNI}",
    "insecure": true
  },
  "up_mbps": 50,
  "down_mbps": 1000
}
CLIENT
    echo

    echo -e "${BLUE}---------- SOCKS5 ----------${NC}"
    echo "地址     : ${SERVER_IP}"
    echo "端口     : ${PORT_SOCKS}"
    echo "用户名   : ${SOCKS_USER}"
    echo "密码     : ${SOCKS_PASS}"
    echo "协议     : SOCKS5"
    echo
}

uninstall_singbox() {
    echo -e "${YELLOW}正在卸载 sing-box...${NC}"

    if command -v rc-service >/dev/null 2>&1; then
        rc-service sing-box stop 2>/dev/null || true
        rc-update del sing-box default 2>/dev/null || true
    fi

    rm -f /etc/init.d/sing-box
    rm -f /usr/local/bin/sing-box
    rm -f /usr/local/bin/socks-whitelist
    rm -rf /etc/sing-box
    rm -rf /var/log/sing-box

    echo -e "${GREEN}卸载完成${NC}"
}

#############################################
# 主菜单
#############################################
show_menu() {
    clear
    echo -e "${GREEN}======================================================${NC}"
    echo -e "${GREEN}  sing-box Reality + Hysteria2 + SOCKS5 管理脚本${NC}"
    echo -e "${GREEN}======================================================${NC}"
    echo
    echo "  1) 安装 / 重装"
    echo "  2) 查看当前客户端配置"
    echo "  3) 管理 SOCKS5 白名单"
    echo "  4) 卸载"
    echo "  0) 退出"
    echo
    read -p "请输入选项 [0-4]: " choice

    case $choice in
        1) install_singbox ;;
        2) print_client_config ;;
        3)
            if [ -f /usr/local/bin/socks-whitelist ]; then
                /usr/local/bin/socks-whitelist
            else
                echo -e "${RED}请先安装后再使用白名单管理${NC}"
            fi
            ;;
        4)
            read -p "确认卸载？(y/n): " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                uninstall_singbox
            fi
            ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${NC}" ;;
    esac
}

#############################################
# 安装函数
#############################################
install_singbox() {
    echo -e "${GREEN}开始安装 / 重装...${NC}"
    echo

    # 如果已安装，先卸载
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，先执行卸载...${NC}"
        uninstall_singbox
        echo
    fi

    # 安装依赖
    echo -e "${BLUE}[1/10] 安装依赖...${NC}"
    apk update
    apk add --no-cache bash curl wget tar jq openssl ca-certificates gcompat coreutils

    # 安装 sing-box
    echo -e "${BLUE}[2/10] 安装最新版 sing-box...${NC}"
    mkdir -p /etc/sing-box /var/log/sing-box
    cd /tmp

    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  ARCH=amd64 ;;
        aarch64) ARCH=arm64 ;;
        armv7l)  ARCH=armv7 ;;
        *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
    esac

    VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    echo "下载版本: $VERSION  架构: $ARCH"

    curl -L -o sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${ARCH}.tar.gz"
    tar -xzf sing-box.tar.gz
    cp sing-box-*/sing-box /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
    rm -rf sing-box* sing-box.tar.gz

    sing-box version

    # 生成随机参数
    echo -e "${BLUE}[3/10] 生成随机密钥与参数...${NC}"
    KEYPAIR=$(sing-box generate reality-keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | awk '/PrivateKey/{print $2}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | awk '/PublicKey/{print $2}')
    UUID=$(sing-box generate uuid)
    SHORT_ID=$(openssl rand -hex 8)
    HY2_PASSWORD=$(openssl rand -base64 16)

    echo -e "${GREEN}生成完成${NC}"
    echo "PrivateKey : $PRIVATE_KEY"
    echo "PublicKey  : $PUBLIC_KEY"
    echo "UUID       : $UUID"
    echo "ShortID    : $SHORT_ID"
    echo "HY2密码    : $HY2_PASSWORD"
    echo

    # 自定义 SOCKS5 用户名密码
    echo -e "${BLUE}[4/10] 设置 SOCKS5 用户名和密码${NC}"
    read -p "SOCKS5 用户名 [默认 socksuser]: " SOCKS_USER
    SOCKS_USER=${SOCKS_USER:-socksuser}

    read -p "SOCKS5 密码 [默认随机生成]: " SOCKS_PASS
    if [ -z "$SOCKS_PASS" ]; then
        SOCKS_PASS=$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-12)
        echo "已随机生成密码: $SOCKS_PASS"
    fi
    echo

    # 自定义端口
    echo -e "${BLUE}[5/10] 设置端口（直接回车使用默认值）${NC}"
    read -p "VLESS Reality 端口 [默认 443]: " PORT_VLESS
    PORT_VLESS=${PORT_VLESS:-443}

    read -p "Hysteria2 端口 [默认 8443]: " PORT_HY2
    PORT_HY2=${PORT_HY2:-8443}

    read -p "SOCKS5 端口 [默认 1080]: " PORT_SOCKS
    PORT_SOCKS=${PORT_SOCKS:-1080}

    echo -e "${GREEN}端口：VLESS=${PORT_VLESS}  HY2=${PORT_HY2}  SOCKS=${PORT_SOCKS}${NC}"
    echo

    # 选择伪装域名
    echo -e "${BLUE}[6/10] 选择 Reality 伪装域名${NC}"
    echo "  1) apps.apple.com"
    echo "  2) www.cartoonbrew.com          (洛杉矶)"
    echo "  3) shop.gcv.org                 (洛杉矶)"
    echo "  4) shin-ei-animation.jp         (日本)"
    echo "  5) www.ritao.co                 (日本)"
    echo "  6) ani-com.hk                   (香港)"
    echo "  7) 手动输入自定义域名"
    echo

    read -p "请输入选项 [1-7] (默认1): " DOMAIN_CHOICE
    DOMAIN_CHOICE=${DOMAIN_CHOICE:-1}

    case $DOMAIN_CHOICE in
        1) SNI="apps.apple.com" ;;
        2) SNI="www.cartoonbrew.com" ;;
        3) SNI="shop.gcv.org" ;;
        4) SNI="shin-ei-animation.jp" ;;
        5) SNI="www.ritao.co" ;;
        6) SNI="ani-com.hk" ;;
        7)
            read -p "请输入自定义伪装域名: " SNI
            [ -z "$SNI" ] && SNI="apps.apple.com"
            ;;
        *) SNI="apps.apple.com" ;;
    esac

    echo -e "${GREEN}已选择伪装域名: $SNI${NC}"
    echo

    # 设置白名单
    echo -e "${BLUE}[7/10] 设置 SOCKS5 IP 白名单${NC}"
    echo -e "${YELLOW}多个 IP 用空格或逗号分隔，支持 CIDR。直接回车表示不放行任何 IP${NC}"
    read -p "请输入允许的 IP（可多个）: " WHITELIST_INPUT

    WHITELIST_JSON=""
    if [ -n "$WHITELIST_INPUT" ]; then
        WHITELIST_INPUT=$(echo "$WHITELIST_INPUT" | tr ',' ' ')
        for ip in $WHITELIST_INPUT; do
            if ! echo "$ip" | grep -q '/'; then
                ip="${ip}/32"
            fi
            if [ -z "$WHITELIST_JSON" ]; then
                WHITELIST_JSON="\"$ip\""
            else
                WHITELIST_JSON="$WHITELIST_JSON, \"$ip\""
            fi
        done
    fi

    if [ -n "$WHITELIST_JSON" ]; then
        echo -e "${GREEN}已设置白名单: $WHITELIST_JSON${NC}"
    else
        echo -e "${YELLOW}未设置白名单，SOCKS5 将拒绝所有连接${NC}"
    fi
    echo

    # 生成证书
    echo -e "${BLUE}[8/10] 生成 Hysteria2 自签证书...${NC}"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout /etc/sing-box/key.pem \
      -out /etc/sing-box/cert.pem \
      -days 3650 \
      -subj "/CN=${SNI}" >/dev/null 2>&1

    # 写入配置
    echo -e "${BLUE}[9/10] 生成配置文件...${NC}"

    if [ -n "$WHITELIST_JSON" ]; then
        SOCKS_RULES=$(cat << RULEEOF
      {
        "inbound": "socks-in",
        "source_ip_cidr": [
          ${WHITELIST_JSON}
        ],
        "action": "route",
        "outbound": "direct"
      },
      {
        "inbound": "socks-in",
        "action": "reject"
      }
RULEEOF
)
    else
        SOCKS_RULES=$(cat << RULEEOF
      {
        "inbound": "socks-in",
        "action": "reject"
      }
RULEEOF
)
    fi

    cat > /etc/sing-box/config.json << EOF
{
  "log": {
    "level": "warn",
    "timestamp": true,
    "output": "/var/log/sing-box/box.log"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": ${PORT_VLESS},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SNI}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${PORT_HY2},
      "users": [
        {
          "password": "${HY2_PASSWORD}"
        }
      ],
      "up_mbps": 100,
      "down_mbps": 100,
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/key.pem"
      }
    },
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "::",
      "listen_port": ${PORT_SOCKS},
      "users": [
        {
          "username": "${SOCKS_USER}",
          "password": "${SOCKS_PASS}"
        }
      ]
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rule_set": [
      {
        "type": "remote",
        "tag": "geoip-cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs"
      }
    ],
    "rules": [
      {
        "ip_is_private": true,
        "action": "reject"
      },
      {
        "rule_set": "geoip-cn",
        "action": "reject"
      },
${SOCKS_RULES}
    ],
    "final": "direct",
    "auto_detect_interface": true
  }
}
EOF

    # 创建服务
    cat > /etc/init.d/sing-box << 'SVCEOF'
#!/sbin/openrc-run
name="sing-box"
description="sing-box proxy service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/sing-box/box.log"
error_log="/var/log/sing-box/box.log"
export GOMAXPROCS=1
export GOMEMLIMIT=80MiB
export GOGC=50
depend() {
    need net
    after firewall
}
start_pre() {
    checkpath -d -m 0755 /var/log/sing-box
    checkpath -d -m 0755 /run
}
SVCEOF

    chmod +x /etc/init.d/sing-box

    # 低内存优化
    if ! grep -q "net.ipv4.tcp_rmem" /etc/sysctl.conf 2>/dev/null; then
    cat >> /etc/sysctl.conf << 'SYSCEOF'
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216
net.ipv4.tcp_slow_start_after_idle = 0
SYSCEOF
    sysctl -p >/dev/null 2>&1
    fi

    # 创建白名单管理工具
    cat > /usr/local/bin/socks-whitelist << 'TOOLEOF'
#!/bin/bash
CONFIG="/etc/sing-box/config.json"
SERVICE="sing-box"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ ! -f "$CONFIG" ]; then
    echo -e "${RED}错误: 配置文件不存在${NC}"
    exit 1
fi

reload_service() {
    echo -e "${YELLOW}正在重载服务...${NC}"
    rc-service $SERVICE restart 2>/dev/null || /etc/init.d/$SERVICE restart
    sleep 1
    echo -e "${GREEN}完成${NC}"
}

ensure_structure() {
    if ! jq -e '.route.rules[] | select(.inbound == "socks-in" and has("source_ip_cidr"))' "$CONFIG" >/dev/null 2>&1; then
        tmp=$(mktemp)
        jq '
          .route.rules as $rules |
          ($rules | map(select(.inbound == "socks-in" and .action == "reject")) | .[0]) as $reject |
          ($rules | map(select(.inbound != "socks-in" or .action != "reject"))) as $others |
          .route.rules = ($others + [
            {"inbound": "socks-in", "source_ip_cidr": [], "action": "route", "outbound": "direct"},
            $reject
          ])
        ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
    fi
}

case "$1" in
    add)
        [ -z "$2" ] && { echo "用法: socks-whitelist add <IP>"; exit 1; }
        IP="$2"
        [[ "$IP" != *"/"* ]] && IP="${IP}/32"
        ensure_structure
        if jq -e --arg ip "$IP" '.route.rules[] | select(.inbound == "socks-in" and has("source_ip_cidr")) | .source_ip_cidr | index($ip)' "$CONFIG" >/dev/null 2>&1; then
            echo -e "${YELLOW}IP $IP 已存在${NC}"
            exit 0
        fi
        tmp=$(mktemp)
        jq --arg ip "$IP" '(.route.rules[] | select(.inbound == "socks-in" and has("source_ip_cidr")) | .source_ip_cidr) += [$ip]' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
        echo -e "${GREEN}已添加 $IP${NC}"
        reload_service
        ;;
    del|rm)
        [ -z "$2" ] && { echo "用法: socks-whitelist del <IP>"; exit 1; }
        IP="$2"
        [[ "$IP" != *"/"* ]] && IP="${IP}/32"
        ensure_structure
        tmp=$(mktemp)
        jq --arg ip "$IP" '(.route.rules[] | select(.inbound == "socks-in" and has("source_ip_cidr")) | .source_ip_cidr) -= [$ip]' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
        echo -e "${GREEN}已删除 $IP${NC}"
        reload_service
        ;;
    list|ls)
        echo -e "${CYAN}当前白名单：${NC}"
        ips=$(jq -r '.route.rules[] | select(.inbound == "socks-in" and has("source_ip_cidr")) | .source_ip_cidr[]?' "$CONFIG" 2>/dev/null)
        [ -z "$ips" ] && echo -e "${YELLOW}(空)${NC}" || echo "$ips"
        ;;
    clear)
        ensure_structure
        tmp=$(mktemp)
        jq '(.route.rules[] | select(.inbound == "socks-in" and has("source_ip_cidr")) | .source_ip_cidr) = []' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
        echo -e "${GREEN}已清空${NC}"
        reload_service
        ;;
    *)
        echo "用法:"
        echo "  socks-whitelist add <IP>     添加"
        echo "  socks-whitelist del <IP>     删除"
        echo "  socks-whitelist list         查看"
        echo "  socks-whitelist clear        清空"
        ;;
esac
TOOLEOF

    chmod +x /usr/local/bin/socks-whitelist

    # 启动服务
    echo -e "${BLUE}[10/10] 启动服务...${NC}"
    sing-box check -c /etc/sing-box/config.json

    rc-service sing-box restart 2>/dev/null || rc-service sing-box start
    rc-update add sing-box default >/dev/null 2>&1

    sleep 1
    if rc-service sing-box status | grep -q "started"; then
        echo -e "${GREEN}服务启动成功！${NC}"
    else
        echo -e "${RED}服务启动失败，请检查日志${NC}"
        exit 1
    fi

    # 保存安装信息
    SERVER_IP=$(curl -s4 --connect-timeout 5 ifconfig.me || curl -s4 --connect-timeout 5 ip.sb || echo "你的服务器IP")

    cat > "$INFO_FILE" << INFOEOF
SERVER_IP="${SERVER_IP}"
SNI="${SNI}"
PORT_VLESS="${PORT_VLESS}"
PORT_HY2="${PORT_HY2}"
PORT_SOCKS="${PORT_SOCKS}"
UUID="${UUID}"
PUBLIC_KEY="${PUBLIC_KEY}"
SHORT_ID="${SHORT_ID}"
HY2_PASSWORD="${HY2_PASSWORD}"
SOCKS_USER="${SOCKS_USER}"
SOCKS_PASS="${SOCKS_PASS}"
PRIVATE_KEY="${PRIVATE_KEY}"
INFOEOF

    # 输出配置
    print_client_config

    echo -e "${GREEN}======================================================${NC}"
    echo -e "${GREEN}安装完成！常用命令：${NC}"
    echo
    echo "  查看配置     : $0          （选择 2）"
    echo "  白名单管理   : socks-whitelist"
    echo "  服务状态     : rc-service sing-box status"
    echo "  重启服务     : rc-service sing-box restart"
    echo "  查看日志     : tail -f /var/log/sing-box/box.log"
    echo -e "${GREEN}======================================================${NC}"
}

#############################################
# 主入口
#############################################
if [ "$1" = "install" ]; then
    install_singbox
elif [ "$1" = "config" ] || [ "$1" = "info" ]; then
    print_client_config
elif [ "$1" = "uninstall" ]; then
    uninstall_singbox
else
    show_menu
fi