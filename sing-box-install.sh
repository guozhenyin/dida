#!/bin/sh

# 先确保安装 bash，然后用 bash 重新执行自己
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

echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}  sing-box Reality + Hysteria2 + SOCKS5 一键安装脚本${NC}"
echo -e "${GREEN}  支持自定义端口 + SOCKS白名单 + 管理工具${NC}"
echo -e "${GREEN}======================================================${NC}"
echo

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}请使用 root 用户运行此脚本${NC}"
    exit 1
fi

#############################################
# 1. 安装依赖（已在开头处理，这里再确认）
#############################################
echo -e "${BLUE}[1/10] 确认依赖已安装...${NC}"
apk add --no-cache bash curl wget tar jq openssl ca-certificates gcompat coreutils >/dev/null 2>&1

#############################################
# 2. 安装最新版 sing-box
#############################################
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

#VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
VERSION="1.14.0"
echo "下载版本: $VERSION  架构: $ARCH"

curl -L -o sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${ARCH}.tar.gz"
tar -xzf sing-box.tar.gz
cp sing-box-*/sing-box /usr/local/bin/
chmod +x /usr/local/bin/sing-box
rm -rf sing-box* sing-box.tar.gz

sing-box version

#############################################
# 3. 生成随机参数
#############################################
echo -e "${BLUE}[3/10] 生成随机密钥与参数...${NC}"

KEYPAIR=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEYPAIR" | awk '/PrivateKey/{print $2}')
PUBLIC_KEY=$(echo "$KEYPAIR" | awk '/PublicKey/{print $2}')

UUID=$(sing-box generate uuid)
SHORT_ID=$(openssl rand -hex 8)
HY2_PASSWORD=$(openssl rand -base64 16)
SOCKS_USER="socksuser"
SOCKS_PASS=$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-12)

echo -e "${GREEN}生成完成${NC}"
echo "PrivateKey : $PRIVATE_KEY"
echo "PublicKey  : $PUBLIC_KEY"
echo "UUID       : $UUID"
echo "ShortID    : $SHORT_ID"
echo "HY2密码    : $HY2_PASSWORD"
echo "SOCKS用户  : $SOCKS_USER"
echo "SOCKS密码  : $SOCKS_PASS"
echo

#############################################
# 4. 自定义端口
#############################################
echo -e "${BLUE}[4/10] 设置端口（直接回车使用默认值）${NC}"

read -p "VLESS Reality 端口 [默认 443]: " PORT_VLESS
PORT_VLESS=${PORT_VLESS:-443}

read -p "Hysteria2 端口 [默认 8443]: " PORT_HY2
PORT_HY2=${PORT_HY2:-8443}

read -p "SOCKS5 端口 [默认 1080]: " PORT_SOCKS
PORT_SOCKS=${PORT_SOCKS:-1080}

echo -e "${GREEN}端口设置：VLESS=${PORT_VLESS}  HY2=${PORT_HY2}  SOCKS=${PORT_SOCKS}${NC}"
echo

#############################################
# 5. 选择伪装域名
#############################################
echo -e "${BLUE}[5/10] 选择 Reality 伪装域名${NC}"
echo
echo "推荐域名："
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
    *)
        SNI="apps.apple.com"
        ;;
esac

echo -e "${GREEN}已选择伪装域名: $SNI${NC}"
echo

#############################################
# 6. 设置 SOCKS5 白名单
#############################################
echo -e "${BLUE}[6/10] 设置 SOCKS5 IP 白名单${NC}"
echo -e "${YELLOW}多个 IP 用空格或逗号分隔，支持 CIDR（如 1.2.3.4 或 1.2.3.0/24）${NC}"
echo -e "${YELLOW}直接回车表示暂时不放行任何 IP（最安全）${NC}"
echo

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

#############################################
# 7. 生成自签证书
#############################################
echo -e "${BLUE}[7/10] 生成 Hysteria2 自签证书...${NC}"
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout /etc/sing-box/key.pem \
  -out /etc/sing-box/cert.pem \
  -days 3650 \
  -subj "/CN=${SNI}" >/dev/null 2>&1

#############################################
# 8. 写入配置文件
#############################################
echo -e "${BLUE}[8/10] 生成 sing-box 配置文件...${NC}"

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
      "down_mbps": 1000,
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

#############################################
# 9. 创建服务
#############################################
echo -e "${BLUE}[9/10] 创建服务并优化...${NC}"

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

#############################################
# 10. 创建白名单管理工具 + 启动服务
#############################################
echo -e "${BLUE}[10/10] 创建白名单管理工具并启动服务...${NC}"

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
    echo -e "${RED}错误: 配置文件不存在 $CONFIG${NC}"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}错误: 需要安装 jq${NC}"
    exit 1
fi

reload_service() {
    echo -e "${YELLOW}正在重载服务...${NC}"
    if command -v rc-service >/dev/null 2>&1; then
        rc-service $SERVICE restart
    else
        /etc/init.d/$SERVICE restart
    fi
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
            {
              "inbound": "socks-in",
              "source_ip_cidr": [],
              "action": "route",
              "outbound": "direct"
            },
            $reject
          ])
        ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
    fi
}

case "$1" in
    add)
        if [ -z "$2" ]; then
            echo "用法: socks-whitelist add <IP或CIDR>"
            exit 1
        fi
        IP="$2"
        [[ "$IP" != *"/"* ]] && IP="${IP}/32"

        ensure_structure

        if jq -e --arg ip "$IP" '.route.rules[] | select(.inbound == "socks-in" and has("source_ip_cidr")) | .source_ip_cidr | index($ip)' "$CONFIG" >/dev/null 2>&1; then
            echo -e "${YELLOW}IP $IP 已在白名单中${NC}"
            exit 0
        fi

        tmp=$(mktemp)
        jq --arg ip "$IP" '(.route.rules[] | select(.inbound == "socks-in" and has("source_ip_cidr")) | .source_ip_cidr) += [$ip]' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
        echo -e "${GREEN}已添加 $IP${NC}"
        reload_service
        ;;
    del|remove|rm)
        if [ -z "$2" ]; then
            echo "用法: socks-whitelist del <IP或CIDR>"
            exit 1
        fi
        IP="$2"
        [[ "$IP" != *"/"* ]] && IP="${IP}/32"

        ensure_structure

        tmp=$(mktemp)
        jq --arg ip "$IP" '(.route.rules[] | select(.inbound == "socks-in" and has("source_ip_cidr")) | .source_ip_cidr) -= [$ip]' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
        echo -e "${GREEN}已删除 $IP${NC}"
        reload_service
        ;;
    list|ls)
        echo -e "${CYAN}当前 SOCKS5 白名单：${NC}"
        ips=$(jq -r '.route.rules[] | select(.inbound == "socks-in" and has("source_ip_cidr")) | .source_ip_cidr[]?' "$CONFIG" 2>/dev/null)
        if [ -z "$ips" ]; then
            echo -e "${YELLOW}(空)${NC}"
        else
            echo "$ips"
        fi
        ;;
    clear)
        ensure_structure
        tmp=$(mktemp)
        jq '(.route.rules[] | select(.inbound == "socks-in" and has("source_ip_cidr")) | .source_ip_cidr) = []' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
        echo -e "${GREEN}已清空白名单${NC}"
        reload_service
        ;;
    *)
        echo -e "${GREEN}SOCKS5 IP 白名单管理工具${NC}"
        echo
        echo "用法:"
        echo "  socks-whitelist add <IP/CIDR>     添加 IP"
        echo "  socks-whitelist del <IP/CIDR>     删除 IP"
        echo "  socks-whitelist list              查看白名单"
        echo "  socks-whitelist clear             清空白名单"
        exit 1
        ;;
esac
TOOLEOF

chmod +x /usr/local/bin/socks-whitelist

# 启动服务
sing-box check -c /etc/sing-box/config.json

rc-service sing-box restart 2>/dev/null || rc-service sing-box start
rc-update add sing-box default >/dev/null 2>&1

sleep 1
if rc-service sing-box status | grep -q "started"; then
    echo -e "${GREEN}服务启动成功！${NC}"
else
    echo -e "${RED}服务启动失败，请检查日志：tail -f /var/log/sing-box/box.log${NC}"
    exit 1
fi

#############################################
# 输出客户端配置
#############################################
SERVER_IP=$(curl -s4 --connect-timeout 5 ifconfig.me || curl -s4 --connect-timeout 5 ip.sb || curl -s4 --connect-timeout 5 api.ipify.org)
[ -z "$SERVER_IP" ] && SERVER_IP="你的服务器IP"

echo
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}                 安装完成！客户端配置${NC}"
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
if [ -n "$WHITELIST_JSON" ]; then
    echo -e "白名单   : ${GREEN}已启用${NC}"
else
    echo -e "白名单   : ${YELLOW}未设置（当前拒绝所有连接）${NC}"
fi
echo

echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}白名单管理工具已安装！使用方法：${NC}"
echo
echo "  socks-whitelist add 1.2.3.4        # 添加IP"
echo "  socks-whitelist del 1.2.3.4        # 删除IP"
echo "  socks-whitelist list               # 查看白名单"
echo "  socks-whitelist clear              # 清空"
echo
echo -e "${GREEN}其他常用命令：${NC}"
echo "  rc-service sing-box status"
echo "  rc-service sing-box restart"
echo "  tail -f /var/log/sing-box/box.log"
echo -e "${GREEN}======================================================${NC}"