#!/bin/bash
# AWS中国区快速配置脚本

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
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

echo "🇨🇳 AWS中国区部署配置脚本"
echo "================================"

# 检查当前配置
log_info "检查当前配置..."
if [ -f "config/global-config.env" ]; then
    current_region=$(grep "export AWS_REGION=" config/global-config.env | cut -d'"' -f2)
    current_partition=$(grep "export AWS_PARTITION=" config/global-config.env | cut -d'"' -f2 2>/dev/null || echo "aws")
    
    log_info "当前区域: $current_region"
    log_info "当前分区: $current_partition"
else
    log_error "配置文件不存在: config/global-config.env"
    exit 1
fi

# 询问用户是否要配置中国区
echo ""
read -p "是否要配置为AWS中国区? (y/N): " configure_china

if [[ $configure_china =~ ^[Yy]$ ]]; then
    log_info "开始配置AWS中国区..."
    
    # 选择中国区域
    echo ""
    echo "请选择中国区域:"
    echo "1) cn-north-1 (北京)"
    echo "2) cn-northwest-1 (宁夏)"
    read -p "请选择 (1-2): " region_choice
    
    case $region_choice in
        1)
            china_region="cn-north-1"
            ;;
        2)
            china_region="cn-northwest-1"
            ;;
        *)
            log_warning "无效选择，使用默认区域 cn-north-1"
            china_region="cn-north-1"
            ;;
    esac
    
    # 备份原配置
    log_info "备份原配置文件..."
    cp config/global-config.env config/global-config.env.backup.$(date +%Y%m%d_%H%M%S)
    
    # 修改配置文件
    log_info "修改配置文件..."
    
    # 设置中国区分区
    if grep -q "export AWS_PARTITION=" config/global-config.env; then
        sed -i 's/export AWS_PARTITION="aws"/export AWS_PARTITION="aws-cn"/' config/global-config.env
    else
        # 在AWS配置部分添加分区配置
        sed -i '/^# AWS 配置/a export AWS_PARTITION="aws-cn"' config/global-config.env
    fi
    
    # 设置中国区域
    sed -i "s/export AWS_REGION=\".*\"/export AWS_REGION=\"$china_region\"/" config/global-config.env
    
    # 添加中国区配置注释
    sed -i '/^# AWS分区配置/,/^# export AWS_REGION=/c\
# AWS分区配置 (支持中国区)\
# 对于中国区，设置为 "aws-cn"，对于其他区域设置为 "aws"\
export AWS_PARTITION="aws-cn"\
# 中国区配置已启用\
# export AWS_REGION="'$china_region'"' config/global-config.env
    
    log_success "✅ 配置文件已更新"
    log_info "区域: $china_region"
    log_info "分区: aws-cn"
    
    # 提醒用户手动配置
    echo ""
    log_warning "⚠️  请手动更新以下配置项:"
    echo "1. AWS_ACCOUNT_ID - 你的中国区账户ID"
    echo "2. AWS_ACCESS_KEY_ID - 你的中国区Access Key"
    echo "3. AWS_SECRET_ACCESS_KEY - 你的中国区Secret Key"
    echo "4. S3_BUCKET - 你的中国区S3存储桶名称"
    echo "5. GREENGRASS_CORE_DEVICE - 你的中国区Greengrass设备名称"
    
    echo ""
    log_info "编辑配置文件: nano config/global-config.env"
    
    # 验证配置
    echo ""
    read -p "配置完成后，是否要验证AWS连接? (y/N): " verify_connection
    
    if [[ $verify_connection =~ ^[Yy]$ ]]; then
        log_info "验证AWS连接..."
        source config/global-config.env
        
        echo "验证AWS凭证..."
        if aws sts get-caller-identity --region "$AWS_REGION" &> /dev/null; then
            log_success "✅ AWS凭证验证成功"
        else
            log_error "❌ AWS凭证验证失败，请检查配置"
        fi
        
        echo "验证S3存储桶..."
        if aws s3 ls "s3://$S3_BUCKET" --region "$AWS_REGION" &> /dev/null; then
            log_success "✅ S3存储桶访问成功"
        else
            log_error "❌ S3存储桶访问失败，请检查存储桶名称和权限"
        fi
    fi
    
    echo ""
    log_success "🎉 中国区配置完成!"
    echo ""
    echo "下一步操作:"
    echo "1. 确保所有配置项都已正确设置"
    echo "2. 运行构建: ./build-all.sh"
    echo "3. 运行部署: ./deploy-all.sh"
    echo "4. 运行测试: ./test-all.sh --integration"
    
else
    log_info "保持当前配置不变"
fi

echo ""
log_info "配置脚本完成"
