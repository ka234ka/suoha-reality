#!/bin/bash
# suoha.sh - 三模式：Quick Tunnel / 安装服务 / IDX（无 root）
# 目标：保持原有三模式与参数逻辑，IDX 模式使用持久化目录与新版保活（pgrep -f 检测、延迟重启、外网健康检查、降温重启）
# 日志与数据路径在各自 BASE_DIR/logs 下；IDX 使用 /workspace/suoha
# 依赖：curl unzip pgrep awk sed grep base64 (自动安装仅在 root 下)

set -o pipefail

is_root() { [ "$(id -u)" = "0" ]; }

# ==================== 架构与下载地址 ====================
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|x64|amd64)
    XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
    CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
    ;;
  aarch64|arm64)
    XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip"
    CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
    ;;
  i386|i686)
    XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-32.zip"
    CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386"
    ;;
  armv7l|armv7)
    XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip"
    CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm"
    ;;
  *)
    echo "不支持的架构: $ARCH"
    exit 1
    ;;
esac

# ==================== 公共函数 ====================
ensure_deps() {
  local pkgs=("$@") miss=()
  for p in "${pkgs[@]}"; do command -v "$p" >/dev/null 2>&1 || miss+=("$p"); done
  [ "${#miss[@]}" -eq 0 ] && return 0
  if ! is_root; then
    echo "缺少依赖: ${miss[*]}（非 root 无法自动安装），请手动安装或改用 IDX 模式（选项 3）"
    exit 1
  fi
  if command -v apt >/dev/null 2>&1; then
    apt update -y && apt install -y "${pkgs[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${pkgs[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${pkgs[@]}"
  else
    echo "未检测到可用包管理器，请手动安装: ${miss[*]}"
    exit 1
  fi
}

fetch_binaries() {
  local target="$1"
  mkdir -p "$target"
  rm -rf "$target/xray" "$target/cloudflared-linux" "$target/xray.zip" "$target/.tmp_xray"
  echo "[INFO] 下载 Xray 与 cloudflared ..."
  curl -fsSL "$XRAY_URL" -o "$target/xray.zip"
  curl -fsSL "$CF_URL" -o "$target/cloudflared-linux"
  mkdir -p "$target/.tmp_xray"
  unzip -o "$target/xray.zip" -d "$target/.tmp_xray" >/dev/null
  mv "$target/.tmp_xray/xray" "$target/xray"
  chmod +x "$target/xray" "$target/cloudflared-linux"
  rm -rf "$target/.tmp_xray" "$target/xray.zip"
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
{"log":{"access":"none","error":"none","loglevel":"warning"},"inbounds":[{"port":$port,"listen":"127.0.0.1","protocol":"vmess","settings":{"clients":[{"id":"$uuid","alterId":0}]},"streamSettings":{"network":"ws","wsSettings":{"path":"/$path"}}}],"outbounds":[{"protocol":"freedom"}]}
EOF
  else
    cat >"$out"<<EOF
{"log":{"access":"none","error":"none","loglevel":"warning"},"inbounds":[{"port":$port,"listen":"127.0.0.1","protocol":"vless","settings":{"decryption":"none","clients":[{"id":"$uuid"}]},"streamSettings":{"network":"ws","wsSettings":{"path":"/$path"}}}],"outbounds":[{"protocol":"freedom"}]}
EOF
  fi
}

# 生成节点字符串（host 为最终外层域名，如 trycloudflare.com 分配的子域）
print_nodes() {
  local proto="$1" uuid="$2" host="$3" path="$4"
  echo "=== 节点信息 ==="
  if [ -z "$host" ]; then
    echo "[WARN] 暂无外层域名可用，稍后 Cloudflared 输出中会出现 trycloudflare.com 的分配域名。"
    return 0
  fi
  if [ "$proto" = "1" ]; then
    local vmess_json encoded
    vmess_json=$(printf '{"v":"2","ps":"CF_TLS","add":"%s","port":"443","id":"%s","aid":"0","net":"ws","type":"none","host":"%s","path":"/%s","tls":"tls"}' "$host" "$uuid" "$host" "$path")
    encoded=$(printf "%s" "$vmess_json" | base64 | tr -d '\n')
    echo "vmess://$encoded"
  else
    echo "vless://$uuid@$host:443?encryption=none&security=tls&type=ws&host=$host&path=/$path#CF_TLS"
  fi
}

show_login_and_wait() {
  local base="$1" ips="$2"
  echo "=== 将出现授权链接，复制到浏览器登录 Cloudflare 并授权（仅首次需要）==="
  "$base/cloudflared-linux" --edge-ip-version "$ips" --protocol http2 tunnel login
  echo "=== 授权完成后按回车继续 ==="
  read -r
}

get_tunnel_id_after_create() {
  local base="$1" name="$2"
  local out id
  out="$("$base/cloudflared-linux" tunnel create "$name" 2>&1 || true)"
  id="$(printf "%s" "$out" | grep -Eo '[0-9a-fA-F-]{36}' | head -n1)"
  [ -z "$id" ] && id="$("$base/cloudflared-linux" tunnel list 2>/dev/null | awk -v n="$name" 'NR>1 && $2==n{print $1; exit}')"
  printf "%s" "$id"
}

# 从 Cloudflared 日志解析 Quick Tunnel 分配的 URL
extract_quick_host() {
  local logfile="$1"
  grep -Eo 'https://[A-Za-z0-9.-]+trycloudflare\.com' "$logfile" | tail -n1 | sed 's#https://##'
}

# ==================== 新版保活（生成可执行脚本） ====================
# 说明：为了在 IDX 等环境中后台自愈，写出独立 keepalive.sh（便于审计与单独运行）
write_keepalive_script() {
  local base_dir="$1" mode="$2" ips="$3" port="$4" cfg_json="$5" cfg_yaml="$6"
  local script="$base_dir/keepalive.sh"
  local log_dir="$base_dir/logs"
  mkdir -p "$log_dir"
  cat >"$script"<<'EOS'
#!/bin/bash
set -o pipefail

BASE_DIR="{{BASE_DIR}}"
LOG_DIR="$BASE_DIR/logs"
MODE="{{MODE}}"         # quick | named
IPS="{{IPS}}"           # 4 或 6
PORT="{{PORT}}"
CFG_JSON="{{CFG_JSON}}"
CFG_YAML="{{CFG_YAML}}"

cooldown_need=0
cf_fail_count=0
CHECK_INTERVAL=60

start_xray() {
  nohup "$BASE_DIR/xray" run -config "$CFG_JSON" >>"$LOG_DIR/xray.log" 2>&1 &
}

start_cf() {
  if [ "$MODE" = "quick" ]; then
    nohup "$BASE_DIR/cloudflared-linux" --edge-ip-version "$IPS" --protocol http2 --no-autoupdate tunnel --url "http://127.0.0.1:$PORT" >>"$LOG_DIR/cloudflared.log" 2>&1 &
  else
    nohup "$BASE_DIR/cloudflared-linux" --edge-ip-version "$IPS" --protocol http2 --ha-connections 1 --no-autoupdate tunnel --config "$CFG_YAML" run >>"$LOG_DIR/cloudflared.log" 2>&1 &
  fi
}

ext_net_ok() {
  curl -fsS --max-time 3 https://1.1.1.1 >/dev/null 2>&1 || curl -fsS --max-time 3 https://8.8.8.8 >/dev/null 2>&1
}

mkdir -p "$LOG_DIR"

# 初始拉起
pgrep -f "$BASE_DIR/xray" >/dev/null || start_xray
pgrep -f "$BASE_DIR/cloudflared-linux" >/dev/null || start_cf

while true; do
  if ! pgrep -f "$BASE_DIR/xray" >/dev/null; then
    echo "[WARN] $(date '+%F %T') Xray 掉线，5 秒后重启..." | tee -a "$LOG_DIR/keepalive.log"
    sleep 5
    start_xray
  fi

  if ! pgrep -f "$BASE_DIR/cloudflared-linux" >/dev/null; then
    ((cf_fail_count++))
    echo "[WARN] $(date '+%F %T') Cloudflared 掉线（连续${cf_fail_count}次）" | tee -a "$LOG_DIR/keepalive.log"
    if ext_net_ok; then
      if [ "$cf_fail_count" -ge 3 ]; then
        echo "[INFO] $(date '+%F %T') 多次掉线，降温 180 秒" | tee -a "$LOG_DIR/keepalive.log"
        sleep 180
        cf_fail_count=0
      fi
      sleep 5
      start_cf
    else
      echo "[WARN] $(date '+%F %T') 外网不可用，跳过重启" | tee -a "$LOG_DIR/keepalive.log"
    fi
  fi

  sleep "$CHECK_INTERVAL"
done
EOS
  # 占位替换
  sed -i "s#{{BASE_DIR}}#${base_dir}#g" "$script"
  sed -i "s#{{MODE}}#${mode}#g" "$script"
  sed -i "s#{{IPS}}#${ips}#g" "$script"
  sed -i "s#{{PORT}}#${port}#g" "$script"
  sed -i "s#{{CFG_JSON}}#${cfg_json}#g" "$script"
  sed -i "s#{{CFG_YAML}}#${cfg_yaml}#g" "$script"
  chmod +x "$script"
}

# ==================== 运行封装 ====================
start_xray_bg() {
  local base="$1" cfg="$2" log_dir="$3"
  mkdir -p "$log_dir"
  nohup "$base/xray" run -config "$cfg" >>"$log_dir/xray.log" 2>&1 &
}

start_cf_quick_bg() {
  local base="$1" port="$2" ips="$3" log_dir="$4"
  mkdir -p "$log_dir"
  nohup "$base/cloudflared-linux" --edge-ip-version "$ips" --protocol http2 --no-autoupdate tunnel --url "http://127.0.0.1:$port" >>"$log_dir/cloudflared.log" 2>&1 &
}

start_cf_named_bg() {
  local base="$1" ips="$2" yaml="$3" log_dir="$4"
  mkdir -p "$log_dir"
  nohup "$base/cloudflared-linux" --edge-ip-version "$ips" --protocol http2 --ha-connections 1 --no-autoupdate tunnel --config "$yaml" run >>"$log_dir/cloudflared.log" 2>&1 &
}

# ==================== 模式：Quick Tunnel（临时） ====================
quick_tunnel_mode() {
  ensure_deps curl unzip pgrep awk sed grep base64
  local TMP_DIR; TMP_DIR="$(mktemp -d -t suoha-XXXX)"
  local LOG_DIR="$TMP_DIR/logs"
  fetch_binaries "$TMP_DIR"
  gen_params
  echo "选择协议：1) VMess  2) VLESS"; read -rp "输入数字: " proto
  gen_xray_config "$proto" "$PORT" "$UUID" "$URLPATH" "$TMP_DIR/config.json"
  read -rp "Cloudflare IP 版本（4/6，默认 4）: " ips; ips="${ips:-4}"
  start_xray_bg "$TMP_DIR" "$TMP_DIR/config.json" "$LOG_DIR"
  start_cf_quick_bg "$TMP_DIR" "$PORT" "$ips" "$LOG_DIR"
  sleep 2
  # 尝试解析 trycloudflare 网址
  local host=""
  for _ in {1..10}; do
    host="$(extract_quick_host "$LOG_DIR/cloudflared.log")"
    [ -n "$host" ] && break || sleep 1
  done
  print_nodes "$proto" "$UUID" "$host" "$URLPATH"
  echo "[INFO] Cloudflared 日志: $LOG_DIR/cloudflared.log"
  echo "[INFO] Xray 日志:        $LOG_DIR/xray.log"
}

# ==================== 模式：系统服务安装（root） ====================
install_service_mode() {
  ensure_deps curl unzip pgrep
  if ! is_root; then
    echo "需要 root 才能安装为系统服务。"
    exit 1
  fi
  local BASE_DIR="/usr/local/suoha"
  local LOG_DIR="$BASE_DIR/logs"
  mkdir -p "$BASE_DIR" "$LOG_DIR"
  fetch_binaries "$BASE_DIR"
  gen_params
  echo "选择协议：1) VMess  2) VLESS"; read -rp "输入数字: " proto
  gen_xray_config "$proto" "$PORT" "$UUID" "$URLPATH" "$BASE_DIR/config.json"

  # Xray systemd
  cat >/etc/systemd/system/suoha-xray.service <<EOF
[Unit]
Description=Suoha Xray Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BASE_DIR/xray run -config $BASE_DIR/config.json
Restart=always
RestartSec=5s
LimitNOFILE=1048576
StandardOutput=append:$LOG_DIR/xray.log
StandardError=append:$LOG_DIR/xray.log

[Install]
WantedBy=multi-user.target
EOF

  # Cloudflared Quick Tunnel systemd（无需登录/域名）
  cat >/etc/systemd/system/suoha-cf.service <<EOF
[Unit]
Description=Suoha Cloudflared Quick Tunnel
After=network-online.target suoha-xray.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BASE_DIR/cloudflared-linux --edge-ip-version 4 --protocol http2 --no-autoupdate tunnel --url http://127.0.0.1:$PORT
Restart=always
RestartSec=5s
StandardOutput=append:$LOG_DIR/cloudflared.log
StandardError=append:$LOG_DIR/cloudflared.log

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now suoha-xray.service
  systemctl enable --now suoha-cf.service

  echo "[INFO] 已安装为系统服务。Cloudflared 分配域名可从日志中获取：$LOG_DIR/cloudflared.log"
  echo "[INFO] 你的 WS 路径: /$URLPATH, 本地端口: $PORT, UUID: $UUID"
  echo "[HINT] 拿到 trycloudflare.com 域名后，可用下列模板生成节点："
  echo "      VMess:  vmess://(host=分配域名, tls, ws, path=/$URLPATH, id=$UUID)"
  echo "      VLESS:  vless://$UUID@分配域名:443?encryption=none&security=tls&type=ws&host=分配域名&path=/$URLPATH#CF_TLS"
}

# ==================== 模式：IDX（无 root + 持久化 + 保活） ====================
idx_mode() {
  ensure_deps curl unzip pgrep awk sed grep base64
  local BASE_DIR="/workspace/suoha"
  local LOG_DIR="$BASE_DIR/logs"
  mkdir -p "$BASE_DIR" "$LOG_DIR"
  fetch_binaries "$BASE_DIR"
  gen_params
  echo "选择协议：1) VMess  2) VLESS"; read -rp "输入数字: " proto
  gen_xray_config "$proto" "$PORT" "$UUID" "$URLPATH" "$BASE_DIR/config.json"
  read -rp "Cloudflare IP 版本（4/6，默认 4）: " ips; ips="${ips:-4}"

  echo "选择 Cloudflared 模式：1) Quick Tunnel（免登录）  2) Named Tunnel（需登录与域名）"
  read -rp "输入数字: " cfmode

  if [ "$cfmode" = "2" ]; then
    # Named Tunnel（需要账号与域名解析）
    show_login_and_wait "$BASE_DIR" "$ips"
    local TUN_NAME="tun-${UUID:0:8}"
    local TUN_ID; TUN_ID="$(get_tunnel_id_after_create "$BASE_DIR" "$TUN_NAME")"
    if [ -z "$TUN_ID" ]; then
      echo "[ERROR] 创建/查询 Tunnel 失败"; exit 1
    fi
    # 需要用户已在 CF 控制台配置 hostname 的 CNAME 指向此 Tunnel（或用 route 命令）
    read -rp "请输入已在 Cloudflare 解析到此 Tunnel 的 hostname（例如 sub.example.com）: " HOSTNAME
    if [ -z "$HOSTNAME" ]; then
      echo "[ERROR] 未提供 hostname"; exit 1
    fi
    cat > "$BASE_DIR/config.yaml" <<EOF
tunnel: $TUN_ID
credentials-file: $BASE_DIR/$TUN_ID.json
ingress:
  - hostname: $HOSTNAME
    service: http://127.0.0.1:$PORT
  - service: http_status:404
EOF
    start_xray_bg "$BASE_DIR" "$BASE_DIR/config.json" "$LOG_DIR"
    start_cf_named_bg "$BASE_DIR" "$ips" "$BASE_DIR/config.yaml" "$LOG_DIR"

    # 写入并启动保活（named）
    write_keepalive_script "$BASE_DIR" "named" "$ips" "$PORT" "$BASE_DIR/config.json" "$BASE_DIR/config.yaml"
    echo "[INFO] 启动保活循环（前台运行，Ctrl+C 退出）"
    "$BASE_DIR/keepalive.sh"
    # 打印节点（使用用户提供的 HOSTNAME）
    print_nodes "$proto" "$UUID" "$HOSTNAME" "$URLPATH"
  else
    # Quick Tunnel（免登录）
    start_xray_bg "$BASE_DIR" "$BASE_DIR/config.json" "$LOG_DIR"
    start_cf_quick_bg "$BASE_DIR" "$PORT" "$ips" "$LOG_DIR"
    sleep 2
    local host=""
    for _ in {1..20}; do
      host="$(extract_quick_host "$LOG_DIR/cloudflared.log")"
      [ -n "$host" ] && break || sleep 1
    done
    print_nodes "$proto" "$UUID" "$host" "$URLPATH"

    # 写入并启动保活（quick）
    write_keepalive_script "$BASE_DIR" "quick" "$ips" "$PORT" "$BASE_DIR/config.json" ""
    echo "[INFO] 启动保活循环（前台运行，Ctrl+C 退出）"
    "$BASE_DIR/keepalive.sh"
  fi
}

# ==================== 入口菜单与调度 ====================
main_menu() {
  echo "=== Suoha 三模式部署脚本 ==="
  echo "1) Quick Tunnel 临时模式（免登录）"
  echo "2) 安装为系统服务（root）"
  echo "3) Google IDX 模式（无 root + 持久化 + 保活）"
  read -rp "请选择模式 (1/2/3): " mode
  case "$mode" in
    1) quick_tunnel_mode ;;
    2) install_service_mode ;;
    3) idx_mode ;;
    *) echo "无效选择"; exit 1 ;;
  esac
}

main_menu
```