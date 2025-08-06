#!/usr/bin/env python3
"""
SFTP到S3数据同步组件
连接本地SFTP服务器，读取CDC文件，通过Stream Manager上传到S3
"""

import json
import logging
import os
import time
import threading
from datetime import datetime
from typing import Dict, List, Optional, Set
import tempfile
import hashlib

import paramiko
from stream_manager.streammanagerclient import StreamManagerClient
from stream_manager.data import (
    MessageStreamDefinition,
    StrategyOnFull,
    ExportDefinition,
    S3ExportTaskExecutorConfig,
    StatusConfig,
    StatusLevel,
    S3ExportTaskDefinition,
    ReadMessagesOptions
)
from stream_manager.exceptions import ResourceNotFoundException
from stream_manager.util import Util

# 配置日志
logging.basicConfig(
    level=logging.DEBUG,  # 改为DEBUG级别
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class SFTPToS3Component:
    """SFTP到S3数据同步组件"""
    
    def __init__(self):
        # 配置参数
        self.config = {
            # SFTP配置
            'sftp_host': 'localhost',
            'sftp_port': 22,
            'sftp_username': os.getenv('SFTP_USERNAME'),
            'sftp_password': os.getenv('SFTP_PASSWORD'),
            'sftp_remote_path': os.getenv('SFTP_REMOTE_PATH', '/data'),
            
            # S3配置
            's3_bucket': 'zihangh-gg-streammanager-poc',
            's3_key_prefix': 'gg_mysql/sftp-sync/',
            
            # Stream Manager配置
            'stream_name': 'SFTPToS3DataStream_ab',
            'status_stream_name': 'SFTPToS3DataStream_ab_Status',
            
            # 扫描配置
            'scan_interval': 30,  # 30秒扫描间隔
            'max_retries': 5,
            'retry_delay': 10,
        }
        
        # 运行状态
        self.running = False
        self.processed_files: Set[str] = set()
        self.sftp_client: Optional[paramiko.SFTPClient] = None
        self.ssh_client: Optional[paramiko.SSHClient] = None
        self.stream_manager_client: Optional[StreamManagerClient] = None
        
        # 线程
        self.scan_thread: Optional[threading.Thread] = None
        self.status_monitor_thread: Optional[threading.Thread] = None
        
        logger.info("SFTP到S3组件初始化完成")
    
    def setup_stream_manager(self) -> bool:
        """设置Stream Manager - 严格按照GitHub示例"""
        max_retries = 10
        retry_delay = 5
        
        for attempt in range(max_retries):
            try:
                logger.info(f"尝试连接Stream Manager (第{attempt + 1}次/共{max_retries}次)")
                
                # 创建Stream Manager客户端
                self.stream_manager_client = StreamManagerClient()
                logger.info("Stream Manager客户端创建成功")
                
                # 删除已存在的流（重新开始）- 严格按照GitHub示例
                try:
                    self.stream_manager_client.delete_message_stream(self.config['status_stream_name'])
                    logger.info(f"删除已存在的状态流: {self.config['status_stream_name']}")
                except ResourceNotFoundException:
                    pass
                
                try:
                    self.stream_manager_client.delete_message_stream(self.config['stream_name'])
                    logger.info(f"删除已存在的数据流: {self.config['stream_name']}")
                except ResourceNotFoundException:
                    pass
                
                # 创建S3导出配置 - 严格按照GitHub示例
                exports = ExportDefinition(
                    s3_task_executor=[
                        S3ExportTaskExecutorConfig(
                            identifier="S3Export" + self.config['stream_name'],
                            status_config=StatusConfig(
                                status_level=StatusLevel.INFO,
                                status_stream_name=self.config['status_stream_name'],
                            ),
                        )
                    ]
                )
                
                # 创建状态流 - 严格按照GitHub示例
                self.stream_manager_client.create_message_stream(
                    MessageStreamDefinition(
                        name=self.config['status_stream_name'],
                        strategy_on_full=StrategyOnFull.OverwriteOldestData
                    )
                )
                logger.info(f"成功创建状态流: {self.config['status_stream_name']}")
                
                # 创建带S3导出的消息流 - 严格按照GitHub示例
                self.stream_manager_client.create_message_stream(
                    MessageStreamDefinition(
                        name=self.config['stream_name'],
                        strategy_on_full=StrategyOnFull.OverwriteOldestData,
                        export_definition=exports
                    )
                )
                logger.info(f"成功创建S3导出数据流: {self.config['stream_name']}")
                
                return True
                
            except Exception as e:
                logger.error(f"设置Stream Manager失败 (第{attempt + 1}次尝试): {e}")
                if attempt < max_retries - 1:
                    logger.info(f"等待{retry_delay}秒后重试...")
                    time.sleep(retry_delay)
                else:
                    logger.error("所有重试都失败了")
                    return False
        
        return False
    
    def setup_sftp_connection(self) -> bool:
        """设置SFTP连接"""
        try:
            # 创建SSH客户端
            self.ssh_client = paramiko.SSHClient()
            #self.ssh_client.set_missing_host_key_policy(paramiko.AutoAddPolicy())  # 自动添加主机密钥策略（不推荐用于生产环境）
            # 设置主机密钥策略
            # 使用RejectPolicy拒绝未知主机密钥（推荐用于生产环境）
            # Load system and user known_hosts files
            self.ssh_client.load_system_host_keys()
            self.ssh_client.load_host_keys(os.path.expanduser('~/.ssh/known_hosts'))
            # Reject unknown hosts by default
            self.ssh_client.set_missing_host_key_policy(paramiko.RejectPolicy())
            
            # 连接到SFTP服务器
            logger.info(f"连接到SFTP服务器: {self.config['sftp_username']}@{self.config['sftp_host']}:{self.config['sftp_port']}")
            self.ssh_client.connect(
                hostname=self.config['sftp_host'],
                port=self.config['sftp_port'],
                username=self.config['sftp_username'],
                password=self.config['sftp_password'],
                timeout=30
            )
            
            # 创建SFTP客户端
            self.sftp_client = self.ssh_client.open_sftp()
            logger.info("SFTP连接建立成功")
            
            # 测试目录访问
            try:
                file_list = self.sftp_client.listdir(self.config['sftp_remote_path'])
                logger.info(f"SFTP目录访问成功，发现 {len(file_list)} 个文件")
            except Exception as e:
                logger.error(f"SFTP目录访问失败: {e}")
                return False
            
            return True
            
        except Exception as e:
            logger.error(f"SFTP连接失败: {e}")
            return False
    
    def scan_sftp_files(self) -> List[str]:
        """扫描SFTP目录中的文件"""
        try:
            if not self.sftp_client:
                logger.error("SFTP客户端未初始化")
                return []
            
            # 获取目录文件列表
            file_list = self.sftp_client.listdir(self.config['sftp_remote_path'])
            logger.debug(f"SFTP目录中的所有文件: {file_list}")
            
            # 过滤支持的文件类型（JSON和TXT文件）
            supported_files = [f for f in file_list if f.endswith(('.json', '.txt', '.csv', '.log'))]
            logger.debug(f"支持的文件类型: {supported_files}")
            
            # 过滤未处理的文件
            new_files = [f for f in supported_files if f not in self.processed_files]
            logger.debug(f"已处理的文件: {list(self.processed_files)}")
            
            if new_files:
                logger.info(f"发现 {len(new_files)} 个新文件: {new_files[:3]}{'...' if len(new_files) > 3 else ''}")
            else:
                logger.debug(f"扫描完成，未发现新文件。已处理文件数: {len(self.processed_files)}")
            
            return new_files
            
        except Exception as e:
            logger.error(f"扫描SFTP文件失败: {e}")
            return []
    
    def download_and_process_file(self, filename: str) -> bool:
        """下载并处理SFTP文件"""
        local_temp_file = None
        try:
            if not self.sftp_client:
                logger.error("SFTP客户端未初始化")
                return False
            
            # 远程文件路径
            remote_file_path = f"{self.config['sftp_remote_path']}/{filename}"
            
            # 创建临时文件
            with tempfile.NamedTemporaryFile(mode='w+b', delete=False, suffix='.json') as temp_file:
                local_temp_file = temp_file.name
            
            # 下载文件
            logger.info(f"下载文件: {filename}")
            self.sftp_client.get(remote_file_path, local_temp_file)
            
            # 读取并验证JSON内容
            with open(local_temp_file, 'r', encoding='utf-8') as f:
                file_content = f.read()
                json_data = json.loads(file_content)  # 验证JSON格式
            
            # 添加元数据
            processed_data = {
                'source_type': 'sftp_sync',
                'source_filename': filename,
                'sync_timestamp': datetime.utcnow().isoformat() + 'Z',
                'file_size': len(file_content),
                'file_hash': hashlib.md5(file_content.encode(), usedforsecurity=False).hexdigest(),
                'original_data': json_data
            }
            
            # 生成S3键名
            timestamp_str = datetime.utcnow().strftime('%Y/%m/%d/%H%M%S')
            s3_key = f"{self.config['s3_key_prefix']}{timestamp_str}_{filename}"
            
            # 创建S3导出任务 - 严格按照GitHub示例
            s3_export_task = S3ExportTaskDefinition(
                bucket=self.config['s3_bucket'],
                key=s3_key,
                input_url=f"file:{local_temp_file}"
            )
            
            # 发送到Stream Manager - 严格按照GitHub示例
            sequence_number = self.stream_manager_client.append_message(
                self.config['stream_name'],
                Util.validate_and_serialize_to_json_bytes(s3_export_task)
            )
            
            logger.info(f"成功提交S3导出任务: {filename} -> s3://{self.config['s3_bucket']}/{s3_key}")
            logger.info(f"Stream Manager序列号: {sequence_number}")
            
            # 标记文件为已处理
            self.processed_files.add(filename)
            
            return True
            
        except json.JSONDecodeError as e:
            logger.error(f"JSON格式错误 {filename}: {e}")
            return False
        except Exception as e:
            logger.error(f"处理文件失败 {filename}: {e}")
            return False
        finally:
            # 保留临时文件供Stream Manager处理，让系统自动清理/tmp目录
            if local_temp_file and os.path.exists(local_temp_file):
                logger.debug(f"临时文件保留供Stream Manager处理: {local_temp_file}")
            pass
    
    def monitor_s3_export_status(self):
        """监控S3导出状态 - 严格按照GitHub示例"""
        while self.running:
            try:
                if not self.stream_manager_client:
                    time.sleep(5)
                    continue
                
                # 读取状态流消息 - 严格按照GitHub示例
                messages = self.stream_manager_client.read_messages(
                    self.config['status_stream_name'],
                    ReadMessagesOptions(min_message_count=1, read_timeout_millis=1000)
                )
                
                for message in messages:
                    # 反序列化状态消息 - 严格按照GitHub示例
                    try:
                        status_data = json.loads(message.payload.decode('utf-8'))
                        
                        # 检查状态
                        if 'status' in status_data:
                            status = status_data['status']
                            if status == 'Success':
                                logger.info(f"✅ S3上传成功")
                            elif status in ['Failure', 'Canceled']:
                                logger.error(f"❌ S3上传失败: {status_data.get('message', 'Unknown error')}")
                            elif status == 'InProgress':
                                logger.info(f"⏳ S3上传进行中")
                    except Exception as e:
                        logger.debug(f"解析状态消息失败: {e}")
                
            except Exception as e:
                logger.debug(f"读取状态流时出错: {e}")
            
            time.sleep(5)  # 每5秒检查一次状态
    
    def file_scan_loop(self):
        """文件扫描循环"""
        while self.running:
            try:
                # 扫描新文件
                new_files = self.scan_sftp_files()
                
                # 处理每个新文件
                for filename in new_files:
                    if not self.running:
                        break
                    
                    success = self.download_and_process_file(filename)
                    if success:
                        logger.info(f"文件处理成功: {filename}")
                    else:
                        logger.error(f"文件处理失败: {filename}")
                    
                    # 短暂延迟避免过于频繁
                    time.sleep(1)
                
            except Exception as e:
                logger.error(f"文件扫描循环出错: {e}")
            
            # 等待下次扫描
            time.sleep(self.config['scan_interval'])
    
    def start(self):
        """启动组件"""
        logger.info("启动SFTP到S3同步组件...")
        
        # 设置Stream Manager
        if not self.setup_stream_manager():
            raise Exception("Stream Manager设置失败")
        
        # 设置SFTP连接
        if not self.setup_sftp_connection():
            raise Exception("SFTP连接设置失败")
        
        # 启动运行标志
        self.running = True
        
        # 启动文件扫描线程
        self.scan_thread = threading.Thread(target=self.file_scan_loop, daemon=True)
        self.scan_thread.start()
        logger.info("文件扫描线程已启动")
        
        # 启动状态监控线程
        self.status_monitor_thread = threading.Thread(target=self.monitor_s3_export_status, daemon=True)
        self.status_monitor_thread.start()
        logger.info("状态监控线程已启动")
        
        logger.info("SFTP到S3同步组件启动完成")
    
    def stop(self):
        """停止组件"""
        logger.info("停止SFTP到S3同步组件...")
        
        self.running = False
        
        # 等待线程结束
        if self.scan_thread and self.scan_thread.is_alive():
            self.scan_thread.join(timeout=10)
        
        if self.status_monitor_thread and self.status_monitor_thread.is_alive():
            self.status_monitor_thread.join(timeout=10)
        
        # 关闭连接
        if self.sftp_client:
            self.sftp_client.close()
        
        if self.ssh_client:
            self.ssh_client.close()
        
        if self.stream_manager_client:
            self.stream_manager_client.close()
        
        logger.info("SFTP到S3同步组件已停止")
    
    def run(self):
        """运行组件主循环"""
        try:
            self.start()
            
            # 保持运行
            while self.running:
                time.sleep(1)
                
        except KeyboardInterrupt:
            logger.info("收到中断信号，正在停止...")
        except Exception as e:
            logger.error(f"组件运行出错: {e}")
            raise
        finally:
            self.stop()

def main():
    """主函数"""
    logger.info("启动SFTP到S3同步组件")
    
    component = SFTPToS3Component()
    
    try:
        component.run()
    except Exception as e:
        logger.error(f"组件启动失败: {e}")
        raise

if __name__ == "__main__":
    main()
