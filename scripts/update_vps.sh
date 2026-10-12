#!/bin/bash
# ==============================================================================
# gxzb-vps 一键热更新脚本 (拉取 Git 最新代码并重启服务)
# ==============================================================================
set -euo pipefail

APP_DIR="/opt/tender"
cd "$APP_DIR"

echo ">>> [1/4] 拉取 Git 远程仓库最新代码..."
git fetch origin main
git reset --hard origin/main

echo ">>> [2/4] 检查并更新 Python 依赖..."
source "$APP_DIR/venv/bin/activate"
pip install -r requirements.txt --quiet

echo ">>> [3/4] 重启管理面板守护进程服务..."
systemctl restart gxzb-manager.service

echo ">>> [4/4] 检查服务运行状态..."
systemctl status gxzb-manager.service --no-pager | head -n 10

echo ">>> 更新完成！当前版本:"
cat version.json
