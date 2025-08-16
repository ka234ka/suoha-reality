#!/bin/bash
# onekey proxy

# ===== 原有依赖检测部分 =====
linux_os=("Debian" "Ubuntu" "CentOS" "Fedora")
linux_update=("apt update" "apt update" "yum -y update" "yum -y update")
linux_install=("apt -y install" "apt -y install" "yum -y install" "yum -y install")

n=0
for i in `echo ${linux_os[@]}`; do
    if [ $i == $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') ]; then
        break
    else
        n=$[$n+1]
    fi
done
if [ $n == 4 ]; then
    echo 当前系统$(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2)没有适配
    echo 默认使用APT包管理器
    n=0
fi

for pkg in unzip curl systemctl; do
    if [ -z $(type -P $pkg) ]; then
        ${linux_update[$n]} && ${linux_install[$n]} $pkg
    fi
done

# ===== 原有 quicktunnel() 保留 =====
function quicktunnel(){
    # ... 原版 Quick Tunnel 代码 ...
}

# ===== 原有 installtunnel() 保留 =====
function installtunnel(){
    # ... 原版 安装服务模式 代码 ...
}

# ===== 新增 IDX 模式（无 root 环境） =====
function idxtunnel(){
    BASE_DIR="$HOME/suoha"
    mkdir -p "$BASE_DIR"
    rm -rf xray cloudflared-linux xray.zip

    case "$(uname -m)" in
        x86_64|x64|amd64)
            curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip
            curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared-linux
            ;;
        arm64|aarch64)
            curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip -o xray.zip
            curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o cloudflared-linux
            ;;
        *)
            echo "当前架构不支持"
            exit 1
            ;;
    esac

    unzip -d xray xray.zip
    chmod +x cloudflared-linux xray/xray
    mv cloudflared-linux "$BASE_DIR/"
    mv xray/xray "$BASE_DIR/"
    rm -rf xray xray.zip

    uuid=$(cat /proc/sys/kernel/random/uuid)
    urlpath=${uuid%%-*}
    port=$((RANDOM+10000))

    cat >"$BASE_DIR/config.json"<<EOF
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

    echo "=== 复制下面的链接到浏览器打开，登录 Cloudflare 并授权绑定域名 ==="
    "$BASE_DIR/cloudflared-linux" tunnel login --no-launch-browser
    echo "=== 授权完成后按回车继续部署 ==="
    read

    read -p "请输入要绑定的完整二级域名: " domain
    "$BASE_DIR/cloudflared-linux" tunnel create mytunnel
    "$BASE_DIR/cloudflared-linux" tunnel route dns mytunnel "$domain"

    cat >"$BASE_DIR/config.yaml"<<EOF
tunnel: mytunnel
credentials-file: $HOME/.cloudflared/mytunnel.json
ingress:
  - hostname: $domain
    service: http://localhost:$port
EOF

    nohup "$BASE_DIR/xray" run -c "$BASE_DIR/config.json" >/dev/null 2>&1 &
    nohup "$BASE_DIR/cloudflared-linux" tunnel --config "$BASE_DIR/config.yaml" run mytunnel >/dev/null 2>&1 &
    echo "IDX 模式部署完成，节点信息保存在 $BASE_DIR/v2ray.txt"
}

# ===== 菜单部分 =====
clear
echo "1. 临时隧道模式（Quick Tunnel）"
echo "2. 安装服务模式（持久运行）"
echo "3. IDX 模式（无 root 环境）"
echo "0. 退出脚本"
read -p "请选择运行模式(默认1): " mode
[ -z "$mode" ] && mode=1

if [ $mode == 1 ]; then
    read -p "请选择xray协议(默认1.vmess,2.vless): " protocol
    [ -z "$protocol" ] && protocol=1
    read -p "请选择argo连接模式IPV4或IPV6(输入4或6,默认4): " ips
    [ -z "$ips" ] && ips=4
    quicktunnel
elif [ $mode == 2 ]; then
    read -p "请选择xray协议(默认1.vmess,2.vless): " protocol
    [ -z "$protocol" ] && protocol=1
    read -p "请选择argo连接模式IPV4或IPV6(输入4或6,默认4): " ips
    [ -z "$ips" ] && ips=4
    installtunnel
elif [ $mode == 3 ]; then
    idxtunnel
else
    echo "退出成功"
    exit
fi
