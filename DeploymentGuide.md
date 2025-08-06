# 🇨🇳 AWS中国区(cn-north-1) Greengrass部署完整指南, 其他region同样的方式.

基于我们的ab Greengrass CDC解决方案，这里是在中国区部署到Linux设备的详细步骤，明确标注每个步骤的执行环境。

## 🌐 **网络访问要求**

### Linux设备网络白名单配置

**🖥️ Linux设备(Greengrass Core Device)需要访问以下域名和端口：**

#### AWS服务端点
```
# IoT Core 端点
*.iot.cn-north-1.amazonaws.com.cn:443 (HTTPS)
*.iot.cn-north-1.amazonaws.com.cn:8883 (MQTT over TLS)

# S3 端点
s3.cn-north-1.amazonaws.com.cn:443 (HTTPS)
*.s3.cn-north-1.amazonaws.com.cn:443 (HTTPS)

# CloudWatch Logs 端点
logs.cn-north-1.amazonaws.com.cn:443 (HTTPS)

# STS 端点 (Token Exchange)
sts.cn-north-1.amazonaws.com.cn:443 (HTTPS)

# Greengrass 服务端点
greengrass.cn-north-1.amazonaws.com.cn:443 (HTTPS)
```

#### 证书和软件下载
```
# Amazon Root CA 证书
www.amazontrust.com:443 (HTTPS)

# Greengrass Core 软件下载
d2s8p88vqu9w66.cloudfront.net:443 (HTTPS)

# AWS CLI 下载
awscli.amazonaws.com:443 (HTTPS)

# Ubuntu/Debian 软件源
archive.ubuntu.com:80 (HTTP)
archive.ubuntu.com:443 (HTTPS)
security.ubuntu.com:80 (HTTP)
security.ubuntu.com:443 (HTTPS)
```

#### 本地服务端口
```
# MySQL 数据库
localhost:3306 (TCP)

# SFTP 服务
localhost:22 (TCP/SSH)

# Stream Manager (内部通信)
localhost:8088 (TCP)
```

#### 协议要求
- **HTTPS (443)**: AWS API调用、证书下载、软件包下载
- **MQTT over TLS (8883)**: IoT Core设备通信
- **TCP (3306)**: MySQL数据库连接
- **SSH (22)**: SFTP文件传输
- **TCP (8088)**: Greengrass Stream Manager内部通信

## 📋 **第一阶段：环境准备**

### 1.1 Linux设备基础环境
**🖥️ 执行环境：Linux设备(Greengrass Core Device)**

```bash
# 更新系统
sudo apt update && sudo apt upgrade -y

# 安装基础工具
sudo apt install -y curl wget unzip git vim htop

# 安装Java 11 (Greengrass v2要求)
sudo apt install -y openjdk-11-jdk
java -version

# 设置JAVA_HOME
echo 'export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64' >> ~/.bashrc
source ~/.bashrc
```

### 1.2 安装AWS CLI v2
**🖥️ 执行环境：Linux设备(Greengrass Core Device)**

```bash
# 下载AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# 验证安装
aws --version

# 配置中国区凭证
aws configure
# AWS Access Key ID: 你的中国区Access Key
# AWS Secret Access Key: 你的中国区Secret Key  
# Default region name: cn-north-1
# Default output format: json
```

### 1.3 创建Greengrass用户和目录
**🖥️ 执行环境：Linux设备(Greengrass Core Device)**

```bash
# 创建Greengrass用户
sudo useradd --system --create-home ggc_user
sudo groupadd --system ggc_group

# 创建Greengrass目录
sudo mkdir -p /greengrass/v2
sudo chown -R ggc_user:ggc_group /greengrass/v2
```

## 🔧 **第二阶段：测试环境搭建**

### 2.1 MySQL数据库安装和配置
**🖥️ 执行环境：Linux设备(Greengrass Core Device)**

```bash
# 安装MySQL Server
sudo apt install -y mysql-server mysql-client

# 启动MySQL服务
sudo systemctl start mysql
sudo systemctl enable mysql

# 安全配置
sudo mysql_secure_installation
# 设置root密码，移除匿名用户，禁用远程root登录等

# 创建测试数据库和用户
sudo mysql -u root -p
```

**🖥️ 执行环境：Linux设备(Greengrass Core Device) - MySQL命令行**

```sql
-- 在MySQL中执行
CREATE DATABASE testdb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER 'testuser'@'localhost' IDENTIFIED BY 'testpassword';
GRANT ALL PRIVILEGES ON testdb.* TO 'testuser'@'localhost';
FLUSH PRIVILEGES;

USE testdb;

-- 创建测试表
CREATE TABLE sensor_data (
    id INT AUTO_INCREMENT PRIMARY KEY,
    sensor_name VARCHAR(100) NOT NULL,
    temperature DECIMAL(5,2),
    humidity DECIMAL(5,2),
    pressure DECIMAL(7,2),
    location VARCHAR(200),
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_timestamp (timestamp),
    INDEX idx_created_at (created_at)
);

-- 插入测试数据
INSERT INTO sensor_data (sensor_name, temperature, humidity, pressure, location) VALUES
('Sensor_001', 25.5, 60.0, 1013.25, 'Beijing Office'),
('Sensor_002', 26.8, 65.5, 1015.30, 'Shanghai Factory'),
('Sensor_003', 24.2, 58.8, 1012.80, 'Guangzhou Warehouse');

-- 启用binlog (CDC需要)


-- 为testuser添加CDC所需的权限
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'testuser'@'localhost';

-- 添加SELECT权限（如果还没有）
GRANT SELECT ON testdb.* TO 'testuser'@'localhost';
-- 更完整的CDC权限设置
-- GRANT REPLICATION SLAVE, REPLICATION CLIENT, SELECT, RELOAD, SHOW DATABASES, LOCK TABLES ON *.* TO 'testuser'@'localhost';
-- 如果需要，也可以添加SUPER权限（但REPLICATION CLIENT通常就足够了）
-- GRANT SUPER ON *.* TO 'testuser'@'localhost';

-- 刷新权限
FLUSH PRIVILEGES;

-- 验证权限
SHOW GRANTS FOR 'testuser'@'localhost';

-- 退出MySQL
EXIT;
```

**🖥️ 执行环境：Linux设备(Greengrass Core Device)**

```bash
# 配置MySQL binlog
sudo nano /etc/mysql/mysql.conf.d/mysqld.cnf

# 添加以下配置
# [mysqld]
# server-id = 1
# log-bin = mysql-bin
# binlog-format = ROW
# binlog-do-db = testdb

# 重启MySQL
sudo systemctl restart mysql

# 验证binlog配置
mysql -u testuser -ptestpassword -D testdb -e "SHOW VARIABLES LIKE 'log_bin';"
```
### 2.2 SFTP服务器安装和配置
**🖥️ 执行环境：Linux设备(Greengrass Core Device)**

```bash
# 安装OpenSSH Server (通常已安装)
sudo apt install -y openssh-server

# 创建SFTP用户
sudo useradd -m -s /bin/bash sftpuser
echo 'sftpuser:sftppassword123' | sudo chpasswd

# 创建SFTP数据目录
sudo mkdir -p /home/sftpuser/data
sudo chown sftpuser:sftpuser /home/sftpuser/data

# 配置SFTP
sudo nano /etc/ssh/sshd_config

# 启用密码认证
PasswordAuthentication yes

# 启用质询响应认证
ChallengeResponseAuthentication yes

# 允许SFTP子系统
Subsystem sftp internal-sftp

# 添加SFTP配置
# Match User sftpuser
#     ChrootDirectory /home/sftpuser
#     ForceCommand internal-sftp
#     AllowTcpForwarding no
#     X11Forwarding no
#     PasswordAuthentication yes

# 重启SSH服务
sudo systemctl restart ssh

# 创建测试文件
sudo -u sftpuser bash -c 'echo "Test CDC data $(date)" > /home/sftpuser/data/test_cdc_$(date +%Y%m%d_%H%M%S).txt'

# 如果使用ChrootDirectory，需要确保目录权限正确
sudo chown root:root /home/sftpuser
sudo chmod 755 /home/sftpuser

# data目录应该属于sftpuser
sudo chown sftpuser:sftpuser /home/sftpuser/data
sudo chmod 755 /home/sftpuser/data

# 验证SFTP连接
sftp sftpuser@localhost
# 密码: sftppassword123
# sftp> ls data/
# sftp> quit

# 输出环境变量(仅用于demo测试, 生产环境推荐使用Secret Manager来存放密钥)
export SFTP_USERNAME="sftpuser"
export SFTP_PASSWORD="sftppassword123"
export SFTP_REMOTE_PATH="/data"
```

### 2.3 Python环境配置
**🖥️ 执行环境：Linux设备(Greengrass Core Device)**

```bash
# 安装Python 3和pip
sudo apt install -y python3 python3-pip python3-venv

# 安装必要的Python包
pip3 install --user mysql-connector-python boto3 paramiko
# 使用清华大学PyPI镜像源
pip3 install --user -i https://pypi.tuna.tsinghua.edu.cn/simple mysql-connector-python boto3 paramiko
# 或者使用阿里云镜像源
pip3 install --user -i https://mirrors.aliyun.com/pypi/simple/ mysql-connector-python boto3 paramiko
# 或者使用中科大镜像源
pip3 install --user -i https://pypi.mirrors.ustc.edu.cn/simple/ mysql-connector-python boto3 paramiko

# 验证安装
python3 -c "import mysql.connector; print('MySQL connector OK')"
python3 -c "import boto3; print('Boto3 OK')"
python3 -c "import paramiko; print('Paramiko OK')"
```

## 🚀 **第三阶段：AWS IoT和Greengrass配置**

### 3.1 创建IoT Thing和证书
**💻 执行环境：部署环境(开发机/管理机)**

```bash
# 输出AWS credential到环境变量
export AWS_ACCESS_KEY_ID="你的中国区Access Key"
export AWS_SECRET_ACCESS_KEY="你的中国区Secret Key"
export AWS_DEFAULT_REGION=cn-north-1

# 设置变量
THING_NAME="MyGreengrassCore_ab_china"
THING_GROUP_NAME="abGreengrassGroup_China"
REGION="cn-north-1"

# 创建Thing
aws iot create-thing \
    --thing-name $THING_NAME \
    --region $REGION

# 创建Thing Group
aws iot create-thing-group \
    --thing-group-name $THING_GROUP_NAME \
    --region $REGION

# 将Thing添加到Group
aws iot add-thing-to-thing-group \
    --thing-name $THING_NAME \
    --thing-group-name $THING_GROUP_NAME \
    --region $REGION

# 创建证书和密钥
aws iot create-keys-and-certificate \
    --set-as-active \
    --certificate-pem-outfile certs-cn/device.pem.crt \
    --public-key-outfile certs-cn/public.pem.key \
    --private-key-outfile certs-cn/private.pem.key \
    --region $REGION

# 记录证书ARN
CERT_ARN=$(aws iot list-certificates --region $REGION --query 'certificates[0].certificateArn' --output text)
echo "Certificate ARN: $CERT_ARN"
```

### 3.2 创建IAM角色和策略
**💻 执行环境：部署环境(开发机/管理机)**

```bash
# 创建Greengrass服务角色信任策略
cat > greengrass-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "greengrass.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# 创建IAM角色
aws iam create-role \
    --role-name GreengrassV2ServiceRole_China \
    --assume-role-policy-document file://greengrass-trust-policy.json \
    --region $REGION

# 附加AWS管理的策略
aws iam attach-role-policy \
    --role-name GreengrassV2ServiceRole_China \
    --policy-arn arn:aws-cn:iam::aws:policy/service-role/AWSGreengrassResourceAccessRolePolicy \
    --region $REGION

# 创建设备角色信任策略
cat > device-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "credentials.iot.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# 创建设备IAM角色
aws iam create-role \
    --role-name GreengrassV2TokenExchangeRole_China \
    --assume-role-policy-document file://device-trust-policy.json \
    --region $REGION

# 创建设备策略
cat > device-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws-cn:s3:::zihangh-gg-streammanager-poc",
        "arn:aws-cn:s3:::zihangh-gg-streammanager-poc/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ],
      "Resource": "arn:aws-cn:logs:cn-north-1:*:*"
    }
  ]
}
EOF

# 创建并附加策略
aws iam create-policy \
    --policy-name GreengrassV2DevicePolicy_China \
    --policy-document file://device-policy.json \
    --region $REGION

DEVICE_POLICY_ARN=$(aws iam list-policies --query 'Policies[?PolicyName==`GreengrassV2DevicePolicy_China`].Arn' --output text --region $REGION)

aws iam attach-role-policy \
    --role-name GreengrassV2TokenExchangeRole_China \
    --policy-arn $DEVICE_POLICY_ARN \
    --region $REGION
```

### 3.3 创建IoT策略和角色别名
**💻 执行环境：部署环境(开发机/管理机)**

```bash
# 创建IoT策略
cat > iot-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "iot:Connect",
        "iot:Publish",
        "iot:Subscribe",
        "iot:Receive",
        "greengrass:*"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iot create-policy \
    --policy-name GreengrassV2IoTThingPolicy_China \
    --policy-document file://iot-policy.json \
    --region $REGION

# 附加策略到证书
aws iot attach-policy \
    --policy-name GreengrassV2IoTThingPolicy_China \
    --target $CERT_ARN \
    --region $REGION

# 附加证书到Thing
aws iot attach-thing-principal \
    --thing-name $THING_NAME \
    --principal $CERT_ARN \
    --region $REGION

# 创建角色别名
DEVICE_ROLE_ARN=$(aws iam get-role --role-name GreengrassV2TokenExchangeRole_China --query 'Role.Arn' --output text --region $REGION)

aws iot create-role-alias \
    --role-alias GreengrassV2TokenExchangeRoleAlias_China \
    --role-arn $DEVICE_ROLE_ARN \
    --region $REGION

# 获取IoT端点
IOT_ENDPOINT=$(aws iot describe-endpoint --endpoint-type iot:Data-ATS --region $REGION --query 'endpointAddress' --output text)
echo "IoT Endpoint: $IOT_ENDPOINT"
# IoT Endpoint: xxxxxxx.ats.iot.cn-north-1.amazonaws.com.cn
```

### 3.4 传输证书到Linux设备
**💻 执行环境：部署环境(开发机/管理机) → 🖥️ Linux设备**

```bash
# 在部署环境中，将证书文件传输到Linux设备
scp -i "gg_ec2_cn.pem" certs-cn/device.pem.crt certs-cn/private.pem.key certs-cn/public.pem.key ubuntu@52.81.38.46:~/

# 或者使用其他方式传输证书文件到Linux设备
```
## 📦 **第四阶段：安装Greengrass Core**

### 4.1 下载和安装Greengrass Core
**🖥️ 执行环境：Linux设备(Greengrass Core Device)**

```bash
# 下载Greengrass Core v2
curl -s https://d2s8p88vqu9w66.cloudfront.net/releases/greengrass-nucleus-latest.zip -o greengrass-nucleus-latest.zip
unzip greengrass-nucleus-latest.zip -d GreengrassCore

# 移动证书文件（假设已从部署环境传输过来）
sudo mkdir -p /greengrass/v2/certs
sudo mv ~/device.pem.crt /greengrass/v2/certs/
sudo mv ~/private.pem.key /greengrass/v2/certs/
sudo mv ~/public.pem.key /greengrass/v2/certs/

# 下载Amazon根CA证书
sudo curl -o /greengrass/v2/certs/AmazonRootCA1.pem https://www.amazontrust.com/repository/AmazonRootCA1.pem

# 设置权限
sudo chown -R ggc_user:ggc_group /greengrass/v2/certs
sudo chmod 400 /greengrass/v2/certs/private.pem.key
sudo chmod 444 /greengrass/v2/certs/device.pem.crt
sudo chmod 444 /greengrass/v2/certs/AmazonRootCA1.pem
```

### 4.2 配置和启动Greengrass Core
**🖥️ 执行环境：Linux设备(Greengrass Core Device)**

```bash
# 临时配置具有IoT管理权限的用户凭证
aws configure set aws_access_key_id "你的中国区Access Key"
aws configure set aws_secret_access_key "你的中国区Secret Key"
aws configure set region cn-north-1

# 获取必要的ARN（需要从部署环境获取或重新查询）
# 如果在Linux设备上有AWS CLI配置，可以直接查询
DEVICE_ROLE_ARN=$(aws iam get-role --role-name GreengrassV2TokenExchangeRole_China --query 'Role.Arn' --output text --region cn-north-1)
# DEVICE_ROLE_ARN="arn:aws-cn:iam::4058xxxxxxxx:role/GreengrassV2TokenExchangeRole_China"
IOT_ENDPOINT=$(aws iot describe-endpoint --endpoint-type iot:Data-ATS --region cn-north-1 --query 'endpointAddress' --output text)
# IOT_ENDPOINT="xxxxxxxx.ats.iot.cn-north-1.amazonaws.com.cn"

# 安装Greengrass Core
sudo -E java -Droot="/greengrass/v2" -Dlog.store=FILE \
  -jar ./GreengrassCore/lib/Greengrass.jar \
  --aws-region cn-north-1 \
  --thing-name MyGreengrassCore_ab_china \
  --thing-group-name abGreengrassGroup_China \
  --thing-policy-name GreengrassV2IoTThingPolicy_China \
  --tes-role-name GreengrassV2TokenExchangeRole_China \
  --tes-role-alias-name GreengrassV2TokenExchangeRoleAlias_China \
  --component-default-user ggc_user:ggc_group \
  --provision true \
  --setup-system-service true \
  --deploy-dev-tools true

# 安装完成后，清除凭证(出于安全考虑)
aws configure set aws_access_key_id ""
aws configure set aws_secret_access_key ""

# 验证安装
sudo systemctl status greengrass

# 查看日志
sudo tail -f /greengrass/v2/logs/greengrass.log

## 📋 策略架构图

# 设备证书
#     ↓ (受IoT策略控制)
# IoT策略: GreengrassTESCertificatePolicyGreengrassV2TokenExchangeRoleAlias_China
#     ↓ (允许AssumeRole)
# IAM角色: GreengrassV2TokenExchangeRole_China
#     ↓ (受IAM策略控制)  
# IAM策略: GreengrassV2DevicePolicy_China
#     ↓ (定义AWS服务权限)
# AWS服务访问 (S3, CloudWatch Logs等)
```


## 🏗️ **第五阶段：部署CDC组件**

### 5.1 准备项目代码
**💻 执行环境：部署环境(开发机/管理机)**

```bash
# 克隆或下载项目代码
cd /home/ubuntu
git clone <your-repo> ab-greengrass-0805
# 或者上传项目文件

cd ab-greengrass-0805
```

### 5.2 配置中国区环境
**💻 执行环境：部署环境(开发机/管理机)**

```bash
# 运行中国区配置脚本
./setup-china.sh

# 手动编辑配置文件
nano config/global-config.env
```
```bash
# 中国区配置示例 (手动编译配置文件)
export AWS_ACCOUNT_ID="你的中国区账户ID"
export AWS_REGION="cn-north-1"
export AWS_PARTITION="aws-cn"
export AWS_ACCESS_KEY_ID="你的中国区Access Key"
export AWS_SECRET_ACCESS_KEY="你的中国区Secret Key"

export GREENGRASS_CORE_DEVICE="MyGreengrassCore_ab_china"
export GREENGRASS_GROUP_NAME="abGreengrassGroup_China"

export S3_BUCKET="你的中国区S3存储桶名称"
export S3_KEY_PREFIX_DEBEZIUM="gg_mysql/debezium-embedded/"
export S3_KEY_PREFIX_SFTP="gg_mysql/sftp-sync/"
export S3_KEY_PREFIX_MYSQL="gg_mysql/mysql-polling/"

export MYSQL_HOST="localhost"
export MYSQL_PORT="3306"
export MYSQL_DATABASE="testdb"
export MYSQL_USERNAME="testuser"
export MYSQL_PASSWORD="testpassword"

export SFTP_HOST="localhost"
export SFTP_PORT="22"
export SFTP_USERNAME="sftpuser"
export SFTP_PASSWORD="sftppassword123"
export SFTP_REMOTE_PATH="/data"
```

### 5.3 构建和部署组件
**💻 执行环境：部署环境(开发机/管理机)**

```bash
# 加载配置
#source config/global-config.env
source config/global-config-cn.env

# 构建所有组件
./build-all.sh

# 运行预部署测试
./test-all.sh --unit
./test-all.sh --smoke-test

# 模拟部署
./deploy-all.sh --dry-run

# 实际部署
./deploy-all.sh
```

### 5.4 监控部署状态
**🖥️ 执行环境：Linux设备(Greengrass Core Device)**

```bash
# 监控部署状态
sudo tail -f /greengrass/v2/logs/greengrass.log
```

## 🧪 **第六阶段：测试和验证**

### 6.1 运行集成测试
**💻 执行环境：部署环境(开发机/管理机)** (前提条件: 开发机和设备是同一台主机)

```bash
# 运行完整集成测试
./test-all.sh --integration

# 运行性能测试
./test-all.sh --performance

# 运行完整测试套件
./test-all.sh --full
```

### 6.2 验证数据流
**🖥️ 执行环境：Linux设备(Greengrass Core Device)**

```bash
# 插入测试数据到MySQL
mysql -u testuser -ptestpassword -D testdb -e "
INSERT INTO sensor_data (sensor_name, temperature, humidity, pressure, location) 
VALUES ('Test_China_$(date +%s)', 28.5, 72.0, 1018.5, 'Beijing Test Location');"

# 创建SFTP测试文件
sudo -u sftpuser bash -c 'echo "{\"sensor\":\"SFTP_Test\",\"value\":123,\"timestamp\":\"$(date -Iseconds)\"}" > /home/sftpuser/data/test_$(date +%Y%m%d_%H%M%S).json'
```

**💻 执行环境：部署环境(开发机/管理机)**

```bash
# 等待数据处理
sleep 60

# 检查S3中的数据
aws s3 ls s3://$S3_BUCKET/gg_mysql/ --recursive --region cn-north-1

# 查看具体数据内容
aws s3 cp s3://$S3_BUCKET/gg_mysql/debezium-embedded/ . --recursive --region cn-north-1
aws s3 cp s3://$S3_BUCKET/gg_mysql/mysql-polling/ . --recursive --region cn-north-1
aws s3 cp s3://$S3_BUCKET/gg_mysql/sftp-sync/ . --recursive --region cn-north-1
```

### 6.3 监控和日志
**🖥️ 执行环境：Linux设备(Greengrass Core Device)**

```bash
# 查看Greengrass Core状态
sudo systemctl status greengrass

# 查看组件日志
sudo tail -f /greengrass/v2/logs/com.example.DebeziumEmbeddedComponent.log
sudo tail /greengrass/v2/logs/com.example.DebeziumEmbeddedComponent.log -n 20
sudo tail -f /greengrass/v2/logs/com.example.SFTPToS3Component.log
sudo tail /greengrass/v2/logs/com.example.SFTPToS3Component.log -n 20
sudo tail -f /greengrass/v2/logs/com.example.MySQLToS3Component.log

# 查看Stream Manager日志
sudo tail -f /greengrass/v2/logs/aws.greengrass.StreamManager.log
sudo tail /greengrass/v2/logs/aws.greengrass.StreamManager.log -n 40

# 检查组件运行状态
sudo /greengrass/v2/bin/greengrass-cli component list
```

## 🔧 **故障排除**

### 常见问题和解决方案

**🖥️ Linux设备问题排查**

1. **Greengrass Core启动失败**
```bash
# 检查证书权限
ls -la /greengrass/v2/certs/
sudo chown -R ggc_user:ggc_group /greengrass/v2/certs

# 检查网络连接
ping $IOT_ENDPOINT
```

2. **MySQL连接问题**
```bash
# 测试MySQL连接
mysql -u testuser -ptestpassword -D testdb -e "SELECT 1;"

# 检查binlog状态
mysql -u testuser -ptestpassword -D testdb -e "SHOW VARIABLES LIKE 'log_bin';"
```

3. **SFTP连接问题**
```bash
# 测试SFTP连接
sftp sftpuser@localhost

# 检查SSH配置
sudo systemctl status ssh
```

**💻 部署环境问题排查**

1. **组件部署失败**
```bash
# 检查IAM权限
aws sts get-caller-identity --region cn-north-1

# 检查S3权限
aws s3 ls s3://$S3_BUCKET --region cn-north-1
```

## 🔒 **安全配置建议**

### 防火墙配置
**🖥️ 执行环境：Linux设备(Greengrass Core Device)**

```bash
# 配置UFW防火墙（如果使用）
sudo ufw allow 22/tcp    # SSH
sudo ufw allow 443/tcp   # HTTPS
sudo ufw allow 8883/tcp  # MQTT over TLS
sudo ufw enable

# 或者配置iptables
sudo iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT
sudo iptables -A OUTPUT -p tcp --dport 8883 -j ACCEPT
```

### 证书安全
**🖥️ 执行环境：Linux设备(Greengrass Core Device)**

```bash
# 定期轮换证书（建议每年）
# 备份当前证书
sudo cp -r /greengrass/v2/certs /greengrass/v2/certs.backup.$(date +%Y%m%d)

# 设置证书文件不可修改
sudo chattr +i /greengrass/v2/certs/device.pem.crt
sudo chattr +i /greengrass/v2/certs/private.pem.key
```

## 📊 **部署验证清单**

### 🖥️ Linux设备(Greengrass Core Device)
- [ ] Linux环境配置完成
- [ ] 网络白名单配置完成
- [ ] MySQL数据库安装并配置CDC
- [ ] SFTP服务器配置完成
- [ ] AWS CLI配置中国区凭证
- [ ] Greengrass用户和目录创建
- [ ] 证书文件正确放置
- [ ] Greengrass Core安装并运行
- [ ] 组件日志正常
- [ ] 数据库和SFTP测试数据创建
- [ ] 防火墙和安全配置完成

### 💻 部署环境(开发机/管理机)
- [ ] AWS CLI配置中国区凭证
- [ ] IoT Thing和证书创建
- [ ] IAM角色和策略配置
- [ ] 项目代码配置中国区参数
- [ ] 所有组件构建成功
- [ ] 组件部署成功
- [ ] 集成测试通过
- [ ] S3数据验证完成

## 🎯 **执行环境总结**

| 阶段 | Linux设备 | 部署环境 | 说明 |
|------|-----------|----------|------|
| **环境准备** | ✅ | ❌ | 系统配置、软件安装 |
| **测试环境搭建** | ✅ | ❌ | MySQL、SFTP、Python配置 |
| **AWS资源创建** | ❌ | ✅ | IoT Thing、IAM角色、策略 |
| **证书传输** | ✅ | ✅ | 从部署环境传输到Linux设备 |
| **Greengrass安装** | ✅ | ❌ | Core安装和配置 |
| **组件构建部署** | ❌ | ✅ | 代码构建和远程部署 |
| **本地测试** | ✅ | ❌ | 数据插入、日志查看 |
| **远程验证** | ❌ | ✅ | S3数据检查、集成测试 |

## 🎉 **部署完成**

**恭喜！你已经成功在AWS中国区(cn-north-1)部署了完整的ab Greengrass CDC解决方案！**

**关键执行环境分工：**
- **🖥️ Linux设备**：负责运行时环境、数据源、Greengrass Core
- **💻 部署环境**：负责AWS资源管理、组件构建部署、远程监控

**系统现在可以：**
- 🔄 **实时CDC**：Debezium捕获MySQL变更并发送到S3
- 📁 **文件同步**：SFTP文件自动同步到S3
- 📊 **批量轮询**：定期轮询MySQL增量数据到S3
- 📈 **监控告警**：完整的日志和状态监控

**下一步可以：**
- 配置CloudWatch告警
- 设置数据备份策略
- 优化性能参数
- 扩展到多个设备
- 实施安全加固措施
