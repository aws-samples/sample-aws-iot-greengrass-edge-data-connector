#!/bin/bash

# IoT Greengrass CDC 解决方案 - 统一构建脚本
# =====================================================

set -e

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 加载全局配置
source config/global-config.env

# 颜色输出
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

# 显示帮助信息
show_help() {
    echo "IoT Greengrass CDC 解决方案 - 统一构建脚本"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --component <name>    只构建指定组件 (debezium-embedded|sftp-to-s3|mysql-to-s3)"
    echo "  --parallel           并行构建所有组件"
    echo "  --release            发布模式构建"
    echo "  --clean              清理构建产物"
    echo "  --help               显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0                           # 构建所有组件"
    echo "  $0 --component debezium-embedded  # 只构建Debezium组件"
    echo "  $0 --parallel --release      # 并行发布构建"
}

# 检查环境依赖
check_dependencies() {
    log_info "检查环境依赖..."
    
    # 检查Java
    if ! command -v java &> /dev/null; then
        log_error "Java未安装或不在PATH中"
        exit 1
    fi
    
    # 检查Python
    if ! command -v python3 &> /dev/null; then
        log_error "Python3未安装或不在PATH中"
        exit 1
    fi
    
    # 检查AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI未安装或不在PATH中"
        exit 1
    fi
    
    # 检查Gradle (用于Debezium组件)
    if ! command -v gradle &> /dev/null; then
        log_warning "Gradle未安装，将使用gradlew"
    fi
    
    log_success "环境依赖检查通过"
}

# 构建Debezium组件
build_debezium_component() {
    log_info "构建Debezium Embedded组件..."
    
    cd components/debezium-embedded
    
    # 检查是否有gradlew
    if [ -f "gradlew" ]; then
        ./gradlew clean build
    elif command -v gradle &> /dev/null; then
        gradle clean build
    else
        log_error "无法找到Gradle构建工具"
        return 1
    fi
    
    # 验证JAR文件 (实际JAR文件名是1.0.0，但组件版本使用环境变量)
    if [ ! -f "debezium-embedded-cdc-1.0.0.jar" ]; then
        log_error "Debezium JAR文件构建失败"
        return 1
    fi
    
    # 验证配置文件
    if [ ! -f "debezium.properties" ]; then
        log_error "Debezium配置文件不存在"
        return 1
    fi
    
    # 验证recipe文件
    python3 -c "import json; json.load(open('recipe.json'))" || {
        log_error "recipe.json格式验证失败"
        return 1
    }
    
    cd ../..
    log_success "Debezium组件构建完成"
}

# 构建SFTP组件
build_sftp_component() {
    log_info "构建SFTP到S3组件..."
    
    cd components/sftp-to-s3
    
    # 验证Python代码语法
    python3 -m py_compile sftp_to_s3.py || {
        log_error "SFTP组件Python代码语法错误"
        return 1
    }
    
    # 验证依赖文件
    if [ ! -f "requirements.txt" ]; then
        log_error "requirements.txt文件不存在"
        return 1
    fi
    
    # 验证recipe文件
    python3 -c "import json; json.load(open('recipe.json'))" || {
        log_error "recipe.json格式验证失败"
        return 1
    }
    
    cd ../..
    log_success "SFTP组件构建完成"
}

# 构建MySQL组件
build_mysql_component() {
    log_info "构建MySQL到S3轮询组件..."
    
    cd components/mysql-to-s3
    
    # 验证Python代码语法
    python3 -m py_compile mysql_to_s3.py || {
        log_error "MySQL组件Python代码语法错误"
        return 1
    }
    
    # 验证依赖文件
    if [ ! -f "mysql_requirements.txt" ]; then
        log_error "mysql_requirements.txt文件不存在"
        return 1
    fi
    
    # 验证recipe文件
    python3 -c "import json; json.load(open('recipe.json'))" || {
        log_error "recipe.json格式验证失败"
        return 1
    }
    
    cd ../..
    log_success "MySQL组件构建完成"
}

# 并行构建所有组件
build_all_parallel() {
    log_info "开始并行构建所有组件..."
    
    # 创建临时目录存储构建结果
    mkdir -p /tmp/build-results
    
    # 并行构建
    (
        build_debezium_component && echo "debezium-success" > /tmp/build-results/debezium.result
    ) &
    DEBEZIUM_PID=$!
    
    (
        build_sftp_component && echo "sftp-success" > /tmp/build-results/sftp.result
    ) &
    SFTP_PID=$!
    
    (
        build_mysql_component && echo "mysql-success" > /tmp/build-results/mysql.result
    ) &
    MYSQL_PID=$!
    
    # 等待所有构建完成
    wait $DEBEZIUM_PID
    DEBEZIUM_EXIT=$?
    
    wait $SFTP_PID
    SFTP_EXIT=$?
    
    wait $MYSQL_PID
    MYSQL_EXIT=$?
    
    # 检查构建结果
    if [ $DEBEZIUM_EXIT -eq 0 ] && [ $SFTP_EXIT -eq 0 ] && [ $MYSQL_EXIT -eq 0 ]; then
        log_success "所有组件并行构建完成"
        rm -rf /tmp/build-results
        return 0
    else
        log_error "部分组件构建失败"
        rm -rf /tmp/build-results
        return 1
    fi
}

# 顺序构建所有组件
build_all_sequential() {
    log_info "开始顺序构建所有组件..."
    
    build_debezium_component || return 1
    build_sftp_component || return 1
    build_mysql_component || return 1
    
    log_success "所有组件顺序构建完成"
}

# 清理构建产物
clean_build() {
    log_info "清理构建产物..."
    
    # 清理Debezium组件
    if [ -d "components/debezium-embedded" ]; then
        cd components/debezium-embedded
        if [ -f "gradlew" ]; then
            ./gradlew clean
        elif command -v gradle &> /dev/null; then
            gradle clean
        fi
        cd ../..
    fi
    
    # 清理Python缓存
    find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
    find . -name "*.pyc" -delete 2>/dev/null || true
    
    log_success "构建产物清理完成"
}

# 生成构建报告
generate_build_report() {
    log_info "生成构建报告..."
    
    REPORT_FILE="build-report-$(date +%Y%m%d-%H%M%S).txt"
    
    cat > "$REPORT_FILE" << EOF
IoT Greengrass CDC 解决方案构建报告
=====================================

构建时间: $(date)
构建模式: ${BUILD_MODE:-sequential}

组件信息:
---------
1. Debezium Embedded组件
   版本: ${DEBEZIUM_COMPONENT_VERSION}
   状态: $([ -f "components/debezium-embedded/debezium-embedded-cdc-1.0.0.jar" ] && echo "✅ 构建成功" || echo "❌ 构建失败")

2. SFTP到S3组件
   版本: ${SFTP_COMPONENT_VERSION}
   状态: $([ -f "components/sftp-to-s3/sftp_to_s3.py" ] && echo "✅ 构建成功" || echo "❌ 构建失败")

3. MySQL到S3轮询组件
   版本: ${MYSQL_COMPONENT_VERSION}
   状态: $([ -f "components/mysql-to-s3/mysql_to_s3.py" ] && echo "✅ 构建成功" || echo "❌ 构建失败")

文件统计:
---------
$(find components -name "*.py" -o -name "*.jar" -o -name "*.json" | wc -l) 个源文件
$(find components -name "*.py" | xargs wc -l | tail -1 | awk '{print $1}') 行Python代码

下一步:
-------
运行部署脚本: ./deploy-all.sh
运行测试脚本: ./test-all.sh
EOF

    log_success "构建报告已生成: $REPORT_FILE"
}

# 主函数
main() {
    echo "🚀 IoT Greengrass CDC 解决方案 - 统一构建"
    echo "=============================================="
    
    # 解析命令行参数
    COMPONENT=""
    PARALLEL=false
    RELEASE=false
    CLEAN=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --component)
                COMPONENT="$2"
                shift 2
                ;;
            --parallel)
                PARALLEL=true
                shift
                ;;
            --release)
                RELEASE=true
                shift
                ;;
            --clean)
                CLEAN=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # 清理模式
    if [ "$CLEAN" = true ]; then
        clean_build
        exit 0
    fi
    
    # 检查环境依赖
    check_dependencies
    
    # 设置构建模式
    if [ "$RELEASE" = true ]; then
        export BUILD_MODE="release"
        log_info "使用发布模式构建"
    else
        export BUILD_MODE="debug"
        log_info "使用调试模式构建"
    fi
    
    # 构建指定组件
    if [ -n "$COMPONENT" ]; then
        case $COMPONENT in
            debezium-embedded)
                build_debezium_component
                ;;
            sftp-to-s3)
                build_sftp_component
                ;;
            mysql-to-s3)
                build_mysql_component
                ;;
            *)
                log_error "未知组件: $COMPONENT"
                log_info "可用组件: debezium-embedded, sftp-to-s3, mysql-to-s3"
                exit 1
                ;;
        esac
    else
        # 构建所有组件
        if [ "$PARALLEL" = true ]; then
            export BUILD_MODE="${BUILD_MODE}-parallel"
            build_all_parallel
        else
            build_all_sequential
        fi
    fi
    
    # 生成构建报告
    generate_build_report
    
    echo ""
    log_success "🎉 构建完成！"
    echo ""
    echo "下一步操作:"
    echo "  部署所有组件: ./deploy-all.sh"
    echo "  运行测试: ./test-all.sh"
    echo "  查看帮助: ./deploy-all.sh --help"
}

# 执行主函数
main "$@"
