#!/bin/bash
# suoha.sh - 三模式：Quick Tunnel / 安装服务 / IDX（无 root）
# - 修复 cloudflared --no-launch-browser 失效，改为直接输出授权链接 + 暂停等待回车
# - 语法兜底：protocol/ips 默认值，健壮提权判断
# - Quick Tunnel 自动解析 trycloudflare 域名并输出节点
# - vmess 链接 base64 不换行，跨系统兼容

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
  *) echo "不支持的架构: $ARCH"; exit 1;;
esac

ensure_deps() {
  local pkgs=("$@") miss=()
  for p in "${pkgs[@]}"; do command -v "$p" >/dev/null 2>&1 || miss+=("$p"); done
  [ "${#miss[@]}" -eq 0 ] && return 0
  if ! is_root; then
    echo "缺少依赖: ${miss[*]}（非 root 无法自动安装），请手动安装或使用 IDX 模式（选项 3）"
    exit 1
  fi
  if command -v apt >/dev/null 2>&1; then
    apt update -y && apt install -y "${miss[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${miss[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${miss[@]}"
  else
    echo "未检测到可用包管理器，请手动安装: ${miss[*]}"
    exit 1
  fi
}

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

gen_params() {
  UUID="$(cat /proc/sys/kernel/random/uuid)"
  URLPATH="${UUID%%-*}"
  PORT="$(( (RANDOM % 20000) + 10000 ))"
}

gen_xray_config() {
  local proto="$1" port="$2" uuid="$3" path="$4" out="$5"
  if [ "$proto" = "1" ]; then
    cat >"$out"<<EOF
{"inbounds":[{"port":$port,"listen":"127.0.0.1","protocol":"vmess","settings":{"clients":[{"id":"$uuid","alterId":0}]},"streamSettings":{"network":"ws","wsSettings":{"path":"/$path"}}}],"outbounds":[{"protocol":"freedom","settings":{}}]}
EOF
  else
    cat >"$out"<<EOF
{"inbounds":[{"port":$port,"listen":"127.0.0.1","protocol":"vless","settings":{"decryption":"none","clients":[{"id":"$uuid"}]},"streamSettings":{"network":"ws","wsSettings":{"path":"/$path"}}}],"outbounds":[{"protocol":"freedom","settings":{}}]}
EOF
  fi
}

print_nodes() {
  local proto="$1" uuid="$2" host="$3" path="$4"
  echo "=== 节点信息 ==="
  if [ "$proto" = "1" ]; then
    local vmess_json encoded
    vmess_json=$(printf '{"v":"2","ps":"CF_TLS","add":"%s","port":"443","id":"%s","aid":"0","net":"ws","type":"none","host":"%s","path":"/%s","tls":"tls"}' "$host" "$uuid" "$host" "$path")
    # 兼容 busybox/base64：不使用 -w0，改为去掉换行
    encoded=$(printf "%s" "$vmess_json" | base64 2>/dev/null | tr -d '\n')
    echo "vmess://$encoded"
  else
    echo "vless://$uuid@$host:443?encryption=none&security=tls&type=ws&host=$host&path=/$path#CF_TLS"
  fi
}

show_login_and_wait() {
  local base="$1" ips="$2"
  echo "=== 复制下面的链接到浏览器打开，登录 Cloudflare 并授权（选择你的主域）==="
  "$base/cloudflared-linux" --edge-ip-version "$ips" --protocol http2 tunnel login
  echo "=== 授权完成后按回车继续部署 ==="
  read -r
}

get_tunnel_id_after_create() {
  # 从 create 输出和 tunnel list 双重兜底获取 TUN_ID
  local base="$1" name="$2"
  local out id
  out="$("$base/cloudflared-linux" tunnel create "$name" 2>&1 || true)"
  id="$(printf "%s" "$out" | grep -Eo '[0-9a-fA-F-]{36}' | head -n1)"
  if [ -z "$id" ]; then
    sleep 1
    id="$("$base/cloudflared-linux" tunnel list | awk -v n="$name" 'NR>1 && $2==n{print $1; exit}')"
  fi
  printf "%s" "$id"
}

quicktunnel() {
  if ! is_root; then
    echo "临时隧道模式需要 root（写入 /opt/suoha）"; exit 1
  fi
  ensure_deps unzip curl
  local BASE="/opt/suoha"
  fetch_binaries "$BASE"

  [ -z "${protocol:-}" ] && protocol="1"
  [ -z "${ips:-}" ] && ips="4"

  gen_params
  gen_xray_config "$protocol" "$PORT" "$UUID" "$URLPATH" "$BASE/config.json"

  nohup "$BASE/xray" run -config "$BASE/config.json" >/var/log/xray_quick.log 2>&1 &

  # 启动 Quick Tunnel 并解析 trycloudflare 域名
  local QLOG="$BASE/argo_quick.log" host=""
  nohup "$BASE/cloudflared-linux" tunnel --edge-ip-version "$ips" --url "http://127.0.0.1:$PORT" >"$QLOG" 2>&1 &
  for _ in $(seq 1 30); do
    if grep -q "trycloudflare.com" "$QLOG" 2>/dev/null; then
      host="$(grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "$QLOG" | tail -n1 | sed 's#https://##')"
      [ -n "$host" ] && break
    fi
    sleep 1
  done
  [ -z "$host" ] && host="your.trycloudflare.com"
  echo "Quick Tunnel 日志：$QLOG"
  print_nodes "$protocol" "$UUID" "$host" "$URLPATH"
}

installtunnel() {
  if ! is_root; then
    echo "安装服务模式需要 root"; exit 1
  fi
  ensure_deps unzip curl systemctl

  local BASE="/opt/suoha"
  mkdir -p "$BASE"
  fetch_binaries "$BASE"

  [ -z "${protocol:-}" ] && protocol="1"
  [ -z "${ips:-}" ] && ips="4"

  gen_params
  gen_xray_config "$protocol" "$PORT" "$UUID" "$URLPATH" "$BASE/config.json"

  show_login_and_wait "$BASE" "$ips"

  read -rp "请输入要绑定的完整二级域名（例如 sub.example.com）: " DOMAIN
  [ -z "$DOMAIN" ] && { echo "域名不能为空"; exit 1; }

  local NAME TUN_ID
  NAME="$(echo "$DOMAIN" | awk -F. '{print $1}')-$(date +%s)"
  TUN_ID="$(get_tunnel_id_after_create "$BASE" "$NAME")"
  [ -z "$TUN_ID" ] && { echo "未能获取隧道 UUID"; exit 1; }

  "$BASE/cloudflared-linux" tunnel route dns "$NAME" "$DOMAIN"

  cat >"$BASE/config.yaml"<<EOF
tunnel: $TUN_ID
credentials-file: /root/.cloudflared/${TUN_ID}.json
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
RestartSec=3

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
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now xray cloudflared

  echo "Xray 配置: $BASE/config.json"
  echo "cloudflared 配置: $BASE/config.yaml"
  print_nodes "$protocol" "$UUID" "$DOMAIN" "$URLPATH"
}

idxtunnel() {
  # 无 root，全部在 $HOME/suoha 下
  local BASE="$HOME/suoha"
  mkdir -p "$BASE"
  ensure_deps unzip curl

  fetch_binaries "$BASE"

  [ -z "${protocol:-}" ] && protocol="1"
  [ -z "${ips:-}" ] && ips="4"

  gen_params
  gen_xray_config "$protocol" "$PORT" "$UUID" "$URLPATH" "$BASE/config.json"

  show_login_and_wait "$BASE" "$ips"

  read -rp "请输入要绑定的完整二级域名（例如 sub.example.com）: " DOMAIN
  [ -z "$DOMAIN" ] && { echo "域名不能为空"; exit 1; }

  local NAME TUN_ID
  NAME="$(echo "$DOMAIN" | awk -F. '{print $1}')-$(date +%s)"
  TUN_ID="$(get_tunnel_id_after_create "$BASE" "$NAME")"
  [ -z "$TUN_ID" ] && { echo "未能获取隧道 UUID"; exit 1; }

  "$BASE/cloudflared-linux" tunnel route dns "$NAME" "$DOMAIN"

  cat >"$BASE/config.yaml"<<EOF
tunnel: $TUN_ID
credentials-file: $HOME/.cloudflared/${TUN_ID}.json
ingress:
  - hostname: $DOMAIN
    service: http://127.0.0.1:$PORT
  - service: http_status:404
EOF

  nohup "$BASE/xray" run -config "$BASE/config.json" >"$BASE/xray.log" 2>&1 &
  nohup "$BASE/cloudflared-linux" --edge-ip-version "$ips" --protocol http2 tunnel --config "$BASE/config.yaml" run >"$BASE/cloudflared.log" 2>&1 &

  echo "日志：$BASE/xray.log, $BASE/cloudflared.log"
  print_nodes "$protocol" "$UUID" "$DOMAIN" "$URLPATH"
}

uninstall_services() {
  if ! is_root; then
    echo "卸载服务需要 root"; exit 1
  fi
  systemctl disable --now xray cloudflared 2>/dev/null || true
  rm -f /etc/systemd/system/xray.service /etc/systemd/system/cloudflared.service
  systemctl daemon-reload
  rm -rf /opt/suoha
  echo "已卸载服务并清理 /opt/suoha"
}

clean_cache() {
  rm -rf xray xray.zip cloudflared-linux
  echo "已清理当前目录临时下载缓存"
}

# 菜单
clear
echo "请选择运行模式："
echo "1) 临时隧道模式（Quick Tunnel，需 root，写入 /opt/suoha）"
echo "2) 安装服务模式（持久运行，需 root + systemd）"
echo "3) IDX 模式（无 root，\$HOME/suoha）"
echo "4) 卸载服务（需 root）"
echo "5) 清理临时下载缓存"
echo "0) 退出"
read -rp "输入选择(默认1): " mode
[ -z "$mode" ] && mode="1"

# 三种运行模式都可以选择协议与 IP 版本（默认 vmess + IPv4）
if [ "$mode" = "1" ] || [ "$mode" = "2" ] || [ "$mode" = "3" ]; then
  read -rp "请选择 xray 协议 (1=vmess, 2=vless，默认1): " protocol
  [ -z "$protocol" ] && protocol="1"
  case "$protocol" in 1|2) : ;; *) echo "协议无效，默认使用 1(vmess)"; protocol="1";; esac
  read -rp "请选择 Argo IP 版本 (4 或 6，默认4): " ips
  [ -z "$ips" ] && ips="4"
  case "$ips" in 4|6) : ;; *) echo "IP 版本无效，默认使用 4"; ips="4";; esac
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

