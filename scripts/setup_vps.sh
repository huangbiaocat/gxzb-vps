#!/bin/bash
# ==============================================================================
# 广西招投标全流程云端自治与存证监控系统 (gxzb-vps) - VPS 自动化部署与环境初始化脚本
# 支持 OS: Ubuntu 22.04 / 24.04 LTS, Debian 11/12
# ==============================================================================
set -euo pipefail

RED='\033[031m'
GREEN='\033[032m'
YELLOW='\033[033m'
BLUE='\033[034m'
PLAIN='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${PLAIN} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${PLAIN} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${PLAIN} $1"; }
log_err() { echo -e "${RED}[ERROR]${PLAIN} $1"; }

if [ "$(id -u)" != "0" ]; then
    log_err "此脚本必须以 root 权限运行！请使用 sudo bash setup_vps.sh"
    exit 1
fi

APP_DIR="/opt/tender"
LOG_DIR="/opt/tender/logs"
DATA_DIR="/opt/tender/data"
DIST_DIR="/opt/tender/dist"
REPO_URL="https://github.com/huangbiaocat/gxzb-vps.git"

log_info "1. 更新系统软件包缓存并安装必备依赖..."
apt-get update -y
apt-get install -y python3 python3-pip python3-venv git curl rsync jq sqlite3 cron nginx logrotate

log_info "2. 配置应用目录与日志权限..."
mkdir -p "$APP_DIR" "$LOG_DIR" "$DATA_DIR" "$DIST_DIR"

log_info "3. 拉取/同步最新代码库至 $APP_DIR..."
if [ -d "$APP_DIR/.git" ]; then
    log_info "发现已存在 Git 仓库，拉取最新代码..."
    cd "$APP_DIR"
    git fetch origin main
    git reset --hard origin/main
else
    log_info "克隆代码仓库 $REPO_URL ..."
    git clone "$REPO_URL" "$APP_DIR"
fi

cd "$APP_DIR"

log_info "4. 创建独立 Python 虚拟环境 (venv)..."
if [ ! -d "$APP_DIR/venv" ]; then
    python3 -m venv "$APP_DIR/venv"
fi
source "$APP_DIR/venv/bin/activate"
pip install --upgrade pip
pip install -r "$APP_DIR/requirements.txt"

log_info "5. 初始化环境变量配置文件 (.env)..."
if [ ! -f "$APP_DIR/.env" ]; then
    cp "$APP_DIR/.env.example" "$APP_DIR/.env"
    # 生成随机鉴权 Token
    RAND_TOKEN=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
    echo "GXZB_AUTH_TOKEN=${RAND_TOKEN}" >> "$APP_DIR/.env"
    log_success "已自动生成高强度 API 鉴权 Token: ${RAND_TOKEN}"
fi

log_info "6. 安装 systemd 常驻守护进程服务 (gxzb-manager.service)..."
cat << 'SERVICE_EOF' > /etc/systemd/system/gxzb-manager.service
[Unit]
Description=Guangxi Tender Intelligence Web Manager & API Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/tender
Environment="PATH=/opt/tender/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/opt/tender/venv/bin/python -u -m manager.server --port 8080
Restart=always
RestartSec=5
StandardOutput=append:/opt/tender/logs/manager.log
StandardError=append:/opt/tender/logs/manager.err.log

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
systemctl enable gxzb-manager.service
systemctl restart gxzb-manager.service

log_info "7. 配置全自动 Crontab 定时爬取、存证、网站构建与推送任务..."
CRON_JOB="0 8,12,18 * * * cd /opt/tender && /opt/tender/venv/bin/python run_daily.py --cloud --site >> /opt/tender/logs/daily_cron.log 2>&1"
(crontab -l 2>/dev/null | grep -v "run_daily.py" || true; echo "$CRON_JOB") | crontab -

log_info "8. 配置 Nginx 反向代理与静态资源托管..."
cat << 'NGINX_EOF' > /etc/nginx/sites-available/tender
server {
    listen 80;
    listen [::]:80;

    server_name ztb.139771.xyz 8.134.69.22 localhost;

    # 静态日报与大屏静态站点托管
    location / {
        root /opt/tender/dist;
        index index.html;
        try_files $uri $uri/ /index.html =404;
        add_header Cache-Control "no-cache, must-revalidate";
    }

    # 管理面板页面与后端 API 反向代理到内部 8080 端口
    location /manager/ {
        proxy_pass http://127.0.0.1:8080/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:8080/api/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # 静态静态历史归档下载
    location /dist/ {
        alias /opt/tender/dist/;
        autoindex on;
    }
}
NGINX_EOF

if [ ! -L /etc/nginx/sites-enabled/tender ]; then
    ln -s /etc/nginx/sites-available/tender /etc/nginx/sites-enabled/tender
fi

nginx -t
systemctl reload nginx

log_info "9. 配置日志轮转 (logrotate)..."
cat << 'LOGROTATE_EOF' > /etc/logrotate.d/gxzb
/opt/tender/logs/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    copytruncate
}
LOGROTATE_EOF

log_success "=================================================================="
log_success "gxzb-vps 云端自治系统部署配置完成！"
log_success "静态前端站点: https://ztb.139771.xyz/"
log_success "后台管理 API: http://127.0.0.1:8080/ (代理至 /api/ /manager/)"
log_success "当前定时任务: 每天 08:00, 12:00, 18:00 全自动扫描全区并生成发布报告"
log_success "=================================================================="
