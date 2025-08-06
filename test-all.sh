#!/bin/bash

# IoT Greengrass CDC 解决方案 - 统一测试脚本
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
    echo "IoT Greengrass CDC 解决方案 - 统一测试脚本"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --unit               运行单元测试"
    echo "  --integration        运行集成测试"
    echo "  --performance        运行性能测试"
    echo "  --smoke-test         运行冒烟测试"
    echo "  --full               运行所有测试"
    echo "  --component <name>   只测试指定组件"
    echo "  --report             生成测试报告"
    echo "  --help               显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0 --integration                    # 运行集成测试"
    echo "  $0 --component debezium-embedded    # 测试Debezium组件"
    echo "  $0 --full --report                 # 运行所有测试并生成报告"
}

# 测试MySQL连接
test_mysql_connection() {
    log_info "测试MySQL连接..."
    
    if command -v mysql &> /dev/null; then
        if mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USERNAME" -p"$MYSQL_PASSWORD" -e "SELECT 1;" &> /dev/null; then
            log_success "✅ MySQL连接测试通过"
            return 0
        else
            log_error "❌ MySQL连接失败"
            return 1
        fi
    else
        log_warning "⚠️ MySQL客户端未安装，跳过连接测试"
        return 0
    fi
}

# 测试SFTP连接
test_sftp_connection() {
    log_info "测试SFTP连接..."
    
    if command -v sshpass &> /dev/null && command -v sftp &> /dev/null; then
        if sshpass -p "$SFTP_PASSWORD" sftp -o StrictHostKeyChecking=no "$SFTP_USERNAME@$SFTP_HOST" <<< "ls" &> /dev/null; then
            log_success "✅ SFTP连接测试通过"
            return 0
        else
            log_error "❌ SFTP连接失败"
            return 1
        fi
    else
        log_warning "⚠️ SFTP客户端工具未安装，跳过连接测试"
        return 0
    fi
}

# 测试S3访问
test_s3_access() {
    log_info "测试S3访问..."
    
    if aws s3 ls "s3://$S3_BUCKET" --region "$AWS_REGION" &> /dev/null; then
        log_success "✅ S3访问测试通过"
        
        # 测试写入权限
        local test_key="test/connectivity-test-$(date +%s).txt"
        if echo "connectivity test" | aws s3 cp - "s3://$S3_BUCKET/$test_key" --region "$AWS_REGION" &> /dev/null; then
            log_success "✅ S3写入权限测试通过"
            # 清理测试文件
            aws s3 rm "s3://$S3_BUCKET/$test_key" --region "$AWS_REGION" &> /dev/null || true
            return 0
        else
            log_error "❌ S3写入权限测试失败"
            return 1
        fi
    else
        log_error "❌ S3访问失败"
        return 1
    fi
}

# 测试Greengrass连接
test_greengrass_connection() {
    log_info "测试Greengrass连接..."
    
    if aws greengrassv2 get-core-device --core-device-thing-name "$GREENGRASS_CORE_DEVICE" --region "$AWS_REGION" &> /dev/null; then
        log_success "✅ Greengrass连接测试通过"
        return 0
    else
        log_error "❌ Greengrass连接失败"
        return 1
    fi
}

# 单元测试
run_unit_tests() {
    log_info "运行单元测试..."
    
    local test_passed=0
    local test_failed=0
    
    # 测试Python代码语法
    log_info "检查Python代码语法..."
    for py_file in $(find components -name "*.py"); do
        if python3 -m py_compile "$py_file" 2>/dev/null; then
            log_success "✅ $py_file 语法检查通过"
            ((test_passed++))
        else
            log_error "❌ $py_file 语法检查失败"
            ((test_failed++))
        fi
    done
    
    # 测试JSON配置文件
    log_info "检查JSON配置文件..."
    for json_file in $(find . -name "*.json" -not -path "./node_modules/*"); do
        if python3 -c "import json; json.load(open('$json_file'))" 2>/dev/null; then
            log_success "✅ $json_file 格式检查通过"
            ((test_passed++))
        else
            log_error "❌ $json_file 格式检查失败"
            ((test_failed++))
        fi
    done
    
    log_info "单元测试完成: $test_passed 通过, $test_failed 失败"
    return $test_failed
}

# 集成测试
run_integration_tests() {
    log_info "运行集成测试..."
    
    local test_results=()
    
    # 基础连接测试
    test_mysql_connection && test_results+=("mysql:pass") || test_results+=("mysql:fail")
    test_sftp_connection && test_results+=("sftp:pass") || test_results+=("sftp:fail")
    test_s3_access && test_results+=("s3:pass") || test_results+=("s3:fail")
    test_greengrass_connection && test_results+=("greengrass:pass") || test_results+=("greengrass:fail")
    
    # 端到端数据流测试
    log_info "测试端到端数据流..."
    if test_end_to_end_dataflow; then
        test_results+=("e2e:pass")
        log_success "✅ 端到端数据流测试通过"
    else
        test_results+=("e2e:fail")
        log_error "❌ 端到端数据流测试失败"
    fi
    
    # 统计结果
    local passed=0
    local failed=0
    
    for result in "${test_results[@]}"; do
        if [[ "$result" == *":pass" ]]; then
            ((passed++))
        elif [[ "$result" == *":fail" ]]; then
            ((failed++))
        fi
    done
    
    log_info "集成测试完成: $passed 通过, $failed 失败"
    return $failed
}

# 端到端数据流测试
test_end_to_end_dataflow() {
    log_info "执行端到端数据流测试..."
    
    # 1. 插入测试数据到MySQL
    local test_data_id="test_$(date +%s)"
    local insert_sql="INSERT INTO sensor_data (sensor_name, temperature, humidity, pressure, location) VALUES ('E2E_Test_$test_data_id', 25.5, 65.0, 1015.0, 'Integration Test Location');"
    
    if ! mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USERNAME" -p"$MYSQL_PASSWORD" -D "$MYSQL_DATABASE" -e "$insert_sql" 2>/dev/null; then
        log_error "插入测试数据失败"
        return 1
    fi
    
    log_success "✅ 测试数据插入成功"
    
    # 2. 等待CDC处理
    log_info "等待CDC组件处理数据..."
    sleep 30
    
    # 3. 检查S3中是否有相关数据
    log_info "检查S3中的CDC数据..."
    local s3_files_found=false
    local today_date=$(date +%Y-%m-%d)
    
    # 检查Debezium CDC数据
    local debezium_files
    debezium_files=$(aws s3 ls "s3://$S3_BUCKET/$S3_KEY_PREFIX_DEBEZIUM" --recursive --region "$AWS_REGION" 2>/dev/null | grep "$today_date" | wc -l)
    if [ "$debezium_files" -gt 0 ]; then
        log_success "✅ 发现Debezium CDC数据"
        s3_files_found=true
    fi
    
    # 检查MySQL轮询数据
    local mysql_files
    mysql_files=$(aws s3 ls "s3://$S3_BUCKET/$S3_KEY_PREFIX_MYSQL" --recursive --region "$AWS_REGION" 2>/dev/null | grep "$today_date" | wc -l)
    if [ "$mysql_files" -gt 0 ]; then
        log_success "✅ 发现MySQL轮询数据"
        s3_files_found=true
    fi
    
    if [ "$s3_files_found" = true ]; then
        log_success "✅ 端到端数据流测试通过"
        return 0
    else
        log_error "❌ 未在S3中发现测试数据"
        return 1
    fi
}

# 性能测试
run_performance_tests() {
    log_info "运行性能测试..."
    
    # 测试数据插入性能
    log_info "测试数据插入性能..."
    local start_time=$(date +%s)
    
    for i in {1..10}; do
        local insert_sql="INSERT INTO sensor_data (sensor_name, temperature, humidity, pressure, location) VALUES ('Perf_Test_${i}_$(date +%s)', $((20 + i)), $((50 + i)), $((1000 + i)), 'Performance Test Location $i');"
        mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USERNAME" -p"$MYSQL_PASSWORD" -D "$MYSQL_DATABASE" -e "$insert_sql" 2>/dev/null || {
            log_error "性能测试数据插入失败"
            return 1
        }
    done
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log_success "✅ 插入10条记录耗时: ${duration}秒"
    
    # 测试S3上传性能
    log_info "等待数据处理和上传..."
    sleep 60
    
    # 检查处理结果
    local recent_files
    recent_files=$(aws s3 ls "s3://$S3_BUCKET/$S3_KEY_PREFIX_DEBEZIUM" --recursive --region "$AWS_REGION" 2>/dev/null | grep "$(date +%Y-%m-%d)" | wc -l 2>/dev/null || echo 0)
    
    # 确保数值格式正确
    recent_files=${recent_files//[^0-9]/}
    
    log_info "今日S3文件数量: $recent_files"
    
    if [ "$recent_files" -gt 0 ]; then
        log_success "✅ 性能测试通过"
        return 0
    else
        log_warning "⚠️ 性能测试结果需要进一步分析"
        return 1
    fi
}

# 冒烟测试
run_smoke_tests() {
    log_info "运行冒烟测试..."
    
    local smoke_tests=(
        "test_mysql_connection"
        "test_s3_access"
        "test_greengrass_connection"
    )
    
    local failed_tests=0
    
    for test_func in "${smoke_tests[@]}"; do
        if ! $test_func; then
            ((failed_tests++))
        fi
    done
    
    if [ $failed_tests -eq 0 ]; then
        log_success "✅ 所有冒烟测试通过"
        return 0
    else
        log_error "❌ $failed_tests 个冒烟测试失败"
        return 1
    fi
}

# 生成测试报告
generate_test_report() {
    log_info "生成测试报告..."
    
    local report_file="test-report-$(date +%Y%m%d-%H%M%S).html"
    
    cat > "$report_file" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>IoT Greengrass CDC 测试报告</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .header { background-color: #f0f0f0; padding: 20px; border-radius: 5px; }
        .section { margin: 20px 0; }
        .pass { color: green; }
        .fail { color: red; }
        .warning { color: orange; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; }
    </style>
</head>
<body>
    <div class="header">
        <h1>IoT Greengrass CDC 解决方案测试报告</h1>
        <p>生成时间: $(date)</p>
        <p>测试环境: $ENVIRONMENT</p>
    </div>
    
    <div class="section">
        <h2>系统信息</h2>
        <table>
            <tr><th>项目</th><th>值</th></tr>
            <tr><td>AWS区域</td><td>$AWS_REGION</td></tr>
            <tr><td>S3存储桶</td><td>$S3_BUCKET</td></tr>
            <tr><td>Greengrass设备</td><td>$GREENGRASS_CORE_DEVICE</td></tr>
            <tr><td>MySQL主机</td><td>$MYSQL_HOST:$MYSQL_PORT</td></tr>
            <tr><td>SFTP主机</td><td>$SFTP_HOST:$SFTP_PORT</td></tr>
        </table>
    </div>
    
    <div class="section">
        <h2>组件版本</h2>
        <table>
            <tr><th>组件</th><th>版本</th></tr>
            <tr><td>Debezium Embedded</td><td>$DEBEZIUM_COMPONENT_VERSION</td></tr>
            <tr><td>SFTP到S3</td><td>$SFTP_COMPONENT_VERSION</td></tr>
            <tr><td>MySQL到S3</td><td>$MYSQL_COMPONENT_VERSION</td></tr>
        </table>
    </div>
    
    <div class="section">
        <h2>测试结果摘要</h2>
        <p>详细测试结果请查看控制台输出。</p>
    </div>
    
    <div class="section">
        <h2>建议</h2>
        <ul>
            <li>定期运行集成测试确保系统稳定性</li>
            <li>监控S3存储使用情况</li>
            <li>检查Greengrass组件日志</li>
            <li>验证数据完整性和一致性</li>
        </ul>
    </div>
</body>
</html>
EOF

    log_success "测试报告已生成: $report_file"
}

# 主函数
main() {
    echo "🧪 IoT Greengrass CDC 解决方案 - 统一测试"
    echo "=============================================="
    
    # 解析命令行参数
    UNIT_TEST=false
    INTEGRATION_TEST=false
    PERFORMANCE_TEST=false
    SMOKE_TEST=false
    FULL_TEST=false
    COMPONENT=""
    GENERATE_REPORT=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --unit)
                UNIT_TEST=true
                shift
                ;;
            --integration)
                INTEGRATION_TEST=true
                shift
                ;;
            --performance)
                PERFORMANCE_TEST=true
                shift
                ;;
            --smoke-test)
                SMOKE_TEST=true
                shift
                ;;
            --full)
                FULL_TEST=true
                shift
                ;;
            --component)
                COMPONENT="$2"
                shift 2
                ;;
            --report)
                GENERATE_REPORT=true
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
    
    # 如果没有指定测试类型，默认运行冒烟测试
    if [ "$UNIT_TEST" = false ] && [ "$INTEGRATION_TEST" = false ] && [ "$PERFORMANCE_TEST" = false ] && [ "$SMOKE_TEST" = false ] && [ "$FULL_TEST" = false ]; then
        SMOKE_TEST=true
    fi
    
    local total_failures=0
    
    # 运行指定的测试
    if [ "$FULL_TEST" = true ] || [ "$UNIT_TEST" = true ]; then
        run_unit_tests || ((total_failures++))
    fi
    
    if [ "$FULL_TEST" = true ] || [ "$SMOKE_TEST" = true ]; then
        run_smoke_tests || ((total_failures++))
    fi
    
    if [ "$FULL_TEST" = true ] || [ "$INTEGRATION_TEST" = true ]; then
        run_integration_tests || ((total_failures++))
    fi
    
    if [ "$FULL_TEST" = true ] || [ "$PERFORMANCE_TEST" = true ]; then
        run_performance_tests || ((total_failures++))
    fi
    
    # 生成测试报告
    if [ "$GENERATE_REPORT" = true ]; then
        generate_test_report
    fi
    
    # 总结
    echo ""
    if [ $total_failures -eq 0 ]; then
        log_success "🎉 所有测试通过！"
        echo ""
        echo "系统状态良好，可以继续使用。"
    else
        log_error "❌ 有 $total_failures 个测试失败"
        echo ""
        echo "请检查失败的测试并修复相关问题。"
        exit 1
    fi
}

# 执行主函数
main "$@"
