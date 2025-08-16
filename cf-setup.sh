#!/usr/bin/env bash
set -euo pipefail

echo "=== [1/5] 检查系统环境 ==="
if ! grep -qi nixos /etc/os-release 2>/dev/null; then
  echo "⚠ 当前系统不是 NixOS，脚本可能不完全适配（IDX 通常是 NixOS）"
fi

echo "=== [2/5] 安装 cloudflared（Nix 包源） ==="
nix-env -iA nixpkgs.cloudflared

echo "=== [3/5] 修正 PATH ==="
export PATH="$HOME/.nix-profile/bin:$PATH"
hash -r || true
cloudflared --version || true

echo "=== [4/5] 检查并备份旧证书 ==="
CERT_DIR="$HOME/.cloudflared"
CERT_FILE="$CERT_DIR/cert.pem"
mkdir -p "$CERT_DIR"
if [ -f "$CERT_FILE" ]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  mv "$CERT_FILE" "$CERT_FILE.bak-$TS"
  echo "已备份旧证书为 $CERT_FILE.bak-$TS"
fi

echo "=== [5/5] 登录 Cloudflare Tunnel ==="
"$HOME/.nix-profile/bin/cloudflared" tunnel login

echo "🎯 完成：请在浏览器打开上方输出的 URL 进行授权登录"
