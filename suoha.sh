#!/bin/bash
# one key proxy

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

# Quick Tunnel 模式
function quicktunnel(){
    mkdir -p /opt/suoha/
    rm -rf /opt/suoha/xray /opt/suoha/cloudflared-linux
    case "$(uname -m)" in
        x86_64 | x64 | amd64 )
            curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip
            curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared-linux
            ;;
        i386 | i686 )
            curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-32.zip -o xray.zip
            curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386 -o cloudflared-linux
            ;;
        armv8 | arm64 | aarch64 )
            curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip -o xray.zip
            curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o cloudflared-linux
            ;;
        armv71 )
            curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip -o xray.zip
            curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm -o cloudflared-linux
            ;;
        * )
            echo 当前架构$(uname -m)没有适配
            exit
            ;;
    esac
    unzip -d xray xray.zip
    chmod +x cloudflared-linux xray/xray
    mv cloudflared-linux /opt/suoha/
    mv xray/xray /opt/suoha/
    rm -rf xray xray.zip
    uuid=$(cat /proc/sys/kernel/random/uuid)
    urlpath=$(echo $uuid | awk -F- '{print $1}')
    port=$[$RANDOM+10000]
    cat>/opt/suoha/config.json<<EOF
{
  "inbounds": [{
    "port": $port,
    "listen": "localhost",
    "protocol": "vless",
    "settings": { "decryption": "none", "clients": [{ "id": "$uuid" }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$urlpath" } }
  }],
  "outbounds": [{ "protocol": "freedom", "settings": {} }]
}
EOF
    /opt/suoha/xray run -c /opt/suoha/config.json &
    /opt/suoha/cloudflared-linux tunnel --url http://localhost:$port
}

# 安装服务模式
function installtunnel(){
    mkdir -p /opt/suoha/
    rm -rf /opt/suoha/xray /opt/suoha/cloudflared-linux
    case "$(uname -m)" in
        x86_64 | x64 | amd64 )
            curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip
            curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared-linux
            ;;
        i386 | i686 )
            curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-32.zip -o xray.zip
            curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386 -o cloudflared-linux
            ;;
        armv8 | arm64 | aarch64 )
            curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip -o xray.zip
            curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o cloudflared-linux
            ;;
        armv71 )
            curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip -o xray.zip
            curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm -o cloudflared-linux
            ;;
        * )
            echo 当前架构$(uname -m)没有适配
            exit
            ;;
    esac
    unzip -d xray xray.zip
    chmod +x cloudflared-linux xray/xray
    mv cloudflared-linux /opt/suoha/
    mv xray/xray /opt/suoha/
    rm -rf xray xray.zip
    uuid=$(cat /proc/sys/kernel/random/uuid)
    urlpath=$(echo $uuid | awk -F- '{print $1}')
    port=$[$RANDOM+10000]
    cat>/opt/suoha/config.json<<EOF
{
  "inbounds": [{
    "port": $port,
    "listen": "localhost",
    "protocol": "vless",
    "settings": { "decryption": "none", "clients": [{ "id": "$uuid" }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$urlpath" } }
  }],
  "outbounds": [{ "protocol": "freedom", "settings": {} }]
}
EOF
    echo "=== 复制下面的链接到浏览器打开，登录 Cloudflare 并授权绑定域名 ==="
    /opt/suoha/cloudflared-linux --edge-ip-version auto --protocol http2 tunnel login --no-launch-browser
    echo "=== 授权完成后按回车继续部署 ==="
    read
    /opt/suoha/cloudflared-linux tunnel create mytunnel
    /opt/suoha/cloudflared-linux tunnel route dns mytunnel your.domain.com
    /opt/suoha/cloudflared-linux tunnel run mytunnel &
    # systemd service 创建省略，可按原版保持
}

# 菜单
clear
echo "请选择运行模式："
echo "1) Quick Tunnel（临时）"
echo "2) 安装服务模式（持久运行）"
read -p "输入选择: " mode
case $mode in
    1) quicktunnel ;;
    2) installtunnel ;;
    *) echo "输入无效" ;;
esac
