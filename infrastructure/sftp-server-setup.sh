#!/bin/bash

# SFTP服务器设置脚本
# 为IoT Greengrass CDC解决方案配置SFTP服务器

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 配置变量
SFTP_USER="sftpuser"
SFTP_PASSWORD="sftppassword123"
SFTP_GROUP="sftpusers"
SFTP_HOME="/home/$SFTP_USER"
SFTP_DATA_DIR="$SFTP_HOME/data"

log_info "开始配置SFTP服务器..."

# 1. 安装OpenSSH服务器
log_info "检查并安装OpenSSH服务器..."
if ! command -v sshd &> /dev/null; then
    sudo apt-get update
    sudo apt-get install -y openssh-server
    log_success "OpenSSH服务器安装完成"
else
    log_success "OpenSSH服务器已安装"
fi

# 2. 创建SFTP用户组
log_info "创建SFTP用户组..."
if ! getent group $SFTP_GROUP &> /dev/null; then
    sudo groupadd $SFTP_GROUP
    log_success "SFTP用户组创建完成: $SFTP_GROUP"
else
    log_success "SFTP用户组已存在: $SFTP_GROUP"
fi

# 3. 创建SFTP用户
log_info "创建SFTP用户..."
if ! id $SFTP_USER &> /dev/null; then
    sudo useradd -m -g $SFTP_GROUP -s /bin/bash $SFTP_USER
    echo "$SFTP_USER:$SFTP_PASSWORD" | sudo chpasswd
    log_success "SFTP用户创建完成: $SFTP_USER"
else
    log_success "SFTP用户已存在: $SFTP_USER"
    # 更新密码
    echo "$SFTP_USER:$SFTP_PASSWORD" | sudo chpasswd
    log_success "SFTP用户密码已更新"
fi

# 4. 创建数据目录
log_info "创建SFTP数据目录..."
sudo mkdir -p $SFTP_DATA_DIR
sudo chown $SFTP_USER:$SFTP_GROUP $SFTP_DATA_DIR
sudo chmod 755 $SFTP_DATA_DIR
log_success "SFTP数据目录创建完成: $SFTP_DATA_DIR"

# 5. 配置SSH服务器
log_info "配置SSH服务器..."
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# 添加SFTP配置
sudo tee -a /etc/ssh/sshd_config > /dev/null << EOF

# SFTP Configuration for IoT Greengrass CDC
Match Group $SFTP_GROUP
    ChrootDirectory %h
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
    PasswordAuthentication yes
EOF

log_success "SSH服务器配置完成"

# 6. 设置chroot目录权限
log_info "设置chroot目录权限..."
sudo chown root:root $SFTP_HOME
sudo chmod 755 $SFTP_HOME
log_success "chroot目录权限设置完成"

# 7. 创建README文件
log_info "创建README文件..."
sudo tee $SFTP_DATA_DIR/README.txt > /dev/null << EOF
IoT Greengrass CDC SFTP数据目录
================================

此目录用于存储CDC (Change Data Capture) 文件。

目录结构:
- cdc_events_*.json: CDC事件文件
- README.txt: 此说明文件

注意事项:
1. 此目录会自动同步CDC文件
2. 文件会定期清理以节省空间
3. 请勿手动修改或删除CDC文件

最后更新: $(date)
EOF

sudo chown $SFTP_USER:$SFTP_GROUP $SFTP_DATA_DIR/README.txt
log_success "README文件创建完成"

# 8. 重启SSH服务
log_info "重启SSH服务..."
sudo systemctl restart ssh
sudo systemctl enable ssh
log_success "SSH服务重启完成"

# 9. 测试SFTP连接
log_info "测试SFTP连接..."
if command -v sshpass &> /dev/null; then
    if sshpass -p "$SFTP_PASSWORD" sftp -o StrictHostKeyChecking=no "$SFTP_USER@localhost" <<< "ls" &> /dev/null; then
        log_success "✅ SFTP连接测试成功"
    else
        log_error "❌ SFTP连接测试失败"
    fi
else
    log_warning "⚠️ sshpass未安装，跳过连接测试"
    log_info "可以手动测试: sftp $SFTP_USER@localhost"
fi

# 10. 显示配置信息
echo ""
log_success "🎉 SFTP服务器配置完成！"
echo ""
echo "配置信息:"
echo "  SFTP主机: localhost"
echo "  SFTP端口: 22"
echo "  用户名: $SFTP_USER"
echo "  密码: $SFTP_PASSWORD"
echo "  数据目录: $SFTP_DATA_DIR"
echo ""
echo "测试连接:"
echo "  sftp $SFTP_USER@localhost"
echo ""
echo "注意事项:"
echo "  1. 用户被限制在chroot环境中"
echo "  2. 只能访问 $SFTP_DATA_DIR 目录"
echo "  3. 不支持SSH shell访问"
