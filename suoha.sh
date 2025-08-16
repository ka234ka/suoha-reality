#!/bin/bash
# suoha.sh - 原版 + IDX 模式 + 授权链接修复 + 语法修复

# ---------------------------
# 通用设置与辅助函数
# ---------------------------
set -o pipefail

is_root() { [ "$(id -u)" = "0" ]; }

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|x64|amd64)   XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
                      CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
  aarch64|arm64)      XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip"
                      CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
  i386|i686)          XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-32.zip"
                      CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386" ;;
  armv7l|armv7)       XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip"
                      CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
  *) echo "当前架构不支持: $ARCH"; exit 1;;
esac

# 尝试安装依赖（仅在 root 且存在包管理器时）
ensure_deps() {
  local need_pkgs=("$@")
  local missing=()
  for p in "${need_pkgs[@]}"; do
    command -v "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  [ "${#missing[@]}" -eq 0 ] && return 0

  if ! is_root; then
    echo "缺少依赖: ${missing[*]}（非 root 环境无法自动安装），请手动安装或使用 IDX 模式（选项 3）"
    exit 1
  fi

  if command -v apt >/dev/null 2>&1; then
    apt update -y && apt install -y "${missing[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${missing[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${missing[@]}"
  else
    echo "未检测到可用包管理器，请手动安装依赖: ${missing[*]}"
    exit 1
  fi
}

# 生成 Xray 配置（vmess/vless over ws）
# 参数: $1=protocol(1|2) $2=port $3=uuid $4=urlpath $5=output_file
gen_xray_config() {
  local protocol="$1" port="$2" uuid="$3" urlpath="$4" out="$5"
  if [ "$protocol" = "1" ]; then
    cat >"$out"<<EOF
{
  "inbounds": [{
    "port": $port,
    "listen": "127.0.0.1",
    "protocol": "vmess",
    "settings": { "clients": [{ "id": "$uuid", "alterId": 0 }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "/$urlpath" } }
  }],
  "outbounds": [{ "protocol": "freedom", "settings": {} }]
}
EOF
  else
    cat >"$out"<<EOF
{
  "inbounds": [{
    "port": $port,
    "listen": "127.0.0.1",
    "protocol": "vless",
    "settings": { "decryption": "none", "clients": [{ "id": "$uuid" }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "/$urlpath" } }
  }],
  "outbounds": [{ "protocol": "freedom", "settings": {} }]
}
EOF
  fi
}

# 输出节点信息
# 参数: $1=protocol(1|2) $2=uuid $3=domain_or_host $4=urlpath
print_nodes() {
  local protocol="$1" uuid="$2" host="$3" path="$4"
  echo "=== 节点信息 ==="
  if [ "$protocol" = "1" ]; then
    # vmess
    local vmess_json
    vmess_json=$(printf '{"v":"2","ps":"CF_TLS","add":"%s","port":"443","id":"%s","aid":"0","net":"ws","type":"none","host":"%s","path":"/%s","tls":"tls"}' "$host" "$uuid" "$host" "$path")
    echo "vmess://$(echo -n "$vmess_json" | base64 -w0 2>/dev/null || echo -n "$vmess_json" | base64)"
  else
    # vless
    echo "vless://$uuid@$host:443?encryption=none&security=tls&type=ws&host=$host&path=/$path#CF_TLS"
  fi
}

# 下载 Xray 与 cloudflared 到指定目录
# 参数: $1=target_dir
fetch_binaries() {
  local target="$1"
  mkdir -p "$target"
  rm -rf xray xray.zip cloudflared-linux
  curl -fsSL "$XRAY_URL" -o xray.zip
  curl -fsSL "$CF_URL" -o cloudflared-linux
  unzip -o xray.zip -d xray
  chmod +x cloudflared-linux xray/xray
  mv cloudflared-linux "$target/"
  mv xray/xray "$target/"
  rm -rf xray xray.zip
}

# 生成随机端口/路径/uuid
gen_params() {
  UUID="$(cat /proc/sys/kernel/random/uuid)"
  URLPATH="${UUID%%-*}"
  PORT="$(( (RANDOM % 20000) + 10000 ))"
}

# ---------------------------
# 1) 临时隧道模式（Quick Tunnel）- 原版保持（使用 /opt/suoha，需要 root）
# ---------------------------
quicktunnel() {
  if ! is_root; then
    echo "临时隧道模式需要写入 /opt/suoha/，请使用 root 运行，或改用 IDX 模式（选项 3）"
    exit 1
  fi
  ensure_deps unzip curl
  local BASE="/opt/suoha"
  fetch_binaries "$BASE"

  # 交互参数已在菜单设置，这里读取
  [ -z "${protocol:-}" ] && protocol="1"     # 语法修复：默认 vmess
  [ -z "${ips:-}" ] && ips="4"

  gen_params
  gen_xray_config "$protocol" "$PORT" "$UUID" "$URLPATH" "$BASE/config.json"

  nohup "$BASE/xray" run -c "$BASE/config.json" >/var/log/xray_quick.log 2>&1 &

  echo "启动 Cloudflare Quick Tunnel..."
  # 将临时网址输出至日志，便于查看
  nohup "$BASE/cloudflared-linux" tunnel --edge-ip-version "$ips" --url "http://127.0.0.1:$PORT" >/var/log/argo_quick.log 2>&1 &
  sleep 2
  echo "可在日志中查看临时地址：/var/log/argo_quick.log（搜索 trycloudflare.com）"
  print_nodes "$protocol" "$UUID" "your.trycloudflare.com" "$URLPATH"
}

# ---------------------------
# 2) 安装服务模式（持久运行）- 原版保持并修复授权链接显示（使用 /opt/suoha，需要 root）
# ---------------------------
installtunnel() {
  if ! is_root; then
    echo "安装服务模式需要 root 权限，请使用 sudo 运行，或改用 IDX 模式（选项 3）"
    exit 1
  fi
  ensure_deps unzip curl systemctl

  local BASE="/opt/suoha"
  mkdir -p "$BASE"
  fetch_binaries "$BASE"

  [ -z "${protocol:-}" ] && protocol="1"    # 语法修复：默认 vmess
  [ -z "${ips:-}" ] && ips="4"

  gen_params
  gen_xray_config "$protocol" "$PORT" "$UUID" "$URLPATH" "$BASE/config.json"

  # 强制显示授权链接并等待
  echo "=== 复制下面的链接到浏览器打开，登录 Cloudflare 并授权（选择你的主域）==="
  "$BASE/cloudflared-linux" --edge-ip-version "$ips" --protocol http2 tunnel login --no-launch-browser
  echo "=== 授权完成后按回车继续部署 ==="
  read -r

  # 绑定域名
  read -rp "请输入要绑定的完整二级域名（例如 sub.example.com）: " DOMAIN
  [ -z "$DOMAIN" ] && { echo "域名不能为空"; exit 1; }

  # 隧道名称使用子域名首段，避免重名再拼接随机数
  local NAME="$(echo "$DOMAIN" | awk -F. '{print $1}')-$(date +%s)"
  "$BASE/cloudflared-linux" tunnel create "$NAME"

  # 获取 Tunnel UUID
  local TUN_ID
  TUN_ID="$("$BASE/cloudflared-linux" tunnel list | awk -v n="$NAME" 'NR>1 && $2==n {print $1; exit}')"
  if [ -z "$TUN_ID" ]; then
    # 兜底：取列表中最近一条
    TUN_ID="$("$BASE/cloudflared-linux" tunnel list | awk 'NR==2{print $1}')"
  fi
  [ -z "$TUN_ID" ] && { echo "未能获取隧道 UUID"; exit 1; }

  "$BASE/cloudflared-linux" tunnel route dns "$NAME" "$DOMAIN"

  # 写 cloudflared 配置
  local CRED_FILE="/root/.cloudflared/${TUN_ID}.json"
  cat >"$BASE/config.yaml"<<EOF
tunnel: $TUN_ID
credentials-file: $CRED_FILE
ingress:
  - hostname: $DOMAIN
    service: http://127.0.0.1:$PORT
  - service: http_status:404
EOF

  # systemd 服务
  cat >/etc/systemd/system/xray.service<<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
Type=simple
ExecStart=$BASE/xray run -config $BASE/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/cloudflared.service<<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
ExecStart=$BASE/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel --config $BASE/config.yaml run
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now xray cloudflared

  echo "服务已启动：xray、cloudflared"
  print_nodes "$protocol" "$UUID" "$DOMAIN" "$URLPATH"
  echo "Xray 配置: $BASE/config.json"
  echo "cloudflared 配置: $BASE/config.yaml"
}

# ---------------------------
# 3) IDX 模式（无 root，$HOME 下运行，授权链接显示）
# ---------------------------
idxtunnel() {
  # 不使用 systemd，不写 /opt；全部放入 $HOME/suoha
  local BASE="$HOME/suoha"
  mkdir -p "$BASE"
  ensure_deps unzip curl

  fetch_binaries "$BASE"

  # IDX 模式不再强依赖 protocol/ips 的全局输入，这里再次兜底
  [ -z "${protocol:-}" ] && protocol="1"
  [ -z "${ips:-}" ] && ips="4"

  gen_params
  gen_xray_config "$protocol" "$PORT" "$UUID" "$URLPATH" "$BASE/config.json"

  echo "=== 复制下面的链接到浏览器打开，登录 Cloudflare 并授权（选择你的主域）==="
  "$BASE/cloudflared-linux" --edge-ip-version "$ips" --protocol http2 tunnel login --no-launch-browser
  echo "=== 授权完成后按回车继续部署 ==="
  read -r

  read -rp "请输入要绑定的完整二级域名（例如 sub.example.com）: " DOMAIN
  [ -z "$DOMAIN" ] && { echo "域名不能为空"; exit 1; }

  local NAME="$(echo "$DOMAIN" | awk -F. '{print $1}')-$(date +%s)"
  "$BASE/cloudflared-linux" tunnel create "$NAME"

  # 获取 Tunnel UUID
  local TUN_ID
  TUN_ID="$("$BASE/cloudflared-linux" tunnel list | awk -v n="$NAME" 'NR>1 && $2==n {print $1; exit}')"
  if [ -z "$TUN_ID" ]; then
    TUN_ID="$("$BASE/cloudflared-linux" tunnel list | awk 'NR==2{print $1}')"
  fi
  [ -z "$TUN_ID" ] && { echo "未能获取隧道 UUID"; exit 1; }

  "$BASE/cloudflared-linux" tunnel route dns "$NAME" "$DOMAIN"

  # 写 cloudflared 配置（用户目录）
  local CRED_FILE="$HOME/.cloudflared/${TUN_ID}.json"
  cat >"$BASE/config.yaml"<<EOF
tunnel: $TUN_ID
credentials-file: $CRED_FILE
ingress:
  - hostname: $DOMAIN
    service: http://127.0.0.1:$PORT
  - service: http_status:404
EOF

  # 后台运行（无 systemd）
  nohup "$BASE/xray" run -c "$BASE/config.json" >"$BASE/xray.log" 2>&1 &
  nohup "$BASE/cloudflared-linux" --edge-ip-version "$ips" --protocol http2 tunnel --config "$BASE/config.yaml" run >"$BASE/cloudflared.log" 2>&1 &

  echo "IDX 模式部署完成。日志："
  echo "  $BASE/xray.log"
  echo "  $BASE/cloudflared.log"
  print_nodes "$protocol" "$UUID" "$DOMAIN" "$URLPATH"
}

# ---------------------------
# 卸载服务（可选，保持原有风格）
# ---------------------------
uninstall_services() {
  if ! is_root; then
    echo "卸载服务需要 root 权限"
    exit 1
  fi
  systemctl disable --now xray cloudflared 2>/dev/null || true
  rm -f /etc/systemd/system/xray.service /etc/systemd/system/cloudflared.service
  systemctl daemon-reload
  rm -rf /opt/suoha
  echo "已卸载服务并清理 /opt/suoha"
}

# 清理下载缓存（可选）
clean_cache() {
  rm -rf xray xray.zip cloudflared-linux
  echo "已清理临时下载缓存（当前目录）"
}

# ---------------------------
# 菜单
# ---------------------------
clear
echo "请选择运行模式："
echo "1) 临时隧道模式（Quick Tunnel，需 root，写入 /opt/suoha）"
echo "2) 安装服务模式（持久运行，需 root + systemd）"
echo "3) IDX 模式（无 root，$HOME/suoha）"
echo "4) 卸载服务（需 root）"
echo "5) 清理临时下载缓存"
echo "0) 退出"
read -rp "输入选择(默认1): " mode
[ -z "$mode" ] && mode="1"

# 仅 1/2 模式需要预先询问协议与 IP 版本（保持原版体验）
if [ "$mode" = "1" ] || [ "$mode" = "2" ]; then
  read -rp "请选择 xray 协议 (1=vmess, 2=vless，默认1): " protocol
  [ -z "$protocol" ] && protocol="1"
  if [ "$protocol" != "1" ] && [ "$protocol" != "2" ]; then
    echo "协议输入无效，默认使用 1(vmess)"
    protocol="1"
  fi
  read -rp "请选择 Argo IP 版本 (4 或 6，默认4): " ips
  [ -z "$ips" ] && ips="4"
  if [ "$ips" != "4" ] && [ "$ips" != "6" ]; then
    echo "IP 版本输入无效，默认使用 4"
    ips="4"
  fi
fi

case "$mode" in
  1) quicktunnel ;;
  2) installtunnel ;;
  3) idxtunnel ;;
  4) uninstall_services ;;
  5) clean_cache ;;
  0) echo "退出"; exit 0 ;;
  *) echo "无效选择"; exit 1 ;;
esac

