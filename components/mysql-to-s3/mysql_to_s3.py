#!/usr/bin/env python3
"""
MySQL到S3定时轮询组件
定时轮询MySQL数据库获取增量数据并通过Stream Manager上传到S3
"""

import json
import logging
import os
import time
import threading
from datetime import datetime, timedelta
from decimal import Decimal
from typing import Dict, List, Optional, Any
import mysql.connector
from mysql.connector import Error
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
import re

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class MySQLToS3Component:
    """MySQL到S3定时轮询组件"""
    
    def __init__(self):
        # 配置参数
        self.config = {
            # MySQL配置
            'mysql_host': os.getenv('MYSQL_HOST', 'localhost'),
            'mysql_port': int(os.getenv('MYSQL_PORT', 3306)),
            'mysql_database': os.getenv('MYSQL_DATABASE', 'testdb'),
            'mysql_username': os.getenv('MYSQL_USERNAME', 'testuser'),
            'mysql_password': os.getenv('MYSQL_PASSWORD', 'testpassword'),
            
            # S3配置
            's3_bucket': os.getenv('S3_BUCKET', 'zihangh-gg-streammanager-poc'),
            's3_key_prefix': os.getenv('S3_KEY_PREFIX', 'gg_mysql/mysql-polling/'),
            
            # Stream Manager配置
            'stream_name': 'MySQLPollingDataStream_ab',
            'status_stream_name': 'MySQLPollingDataStream_ab_Status',
            
            # 轮询配置
            'polling_interval': int(os.getenv('POLLING_INTERVAL', 300)),  # 5分钟
            'batch_size': int(os.getenv('BATCH_SIZE', 100)),
            'max_retries': 5,
            'retry_delay': 10,
            
            # 监控表配置
            'monitored_tables': ['sensor_data'],  # 可配置监控的表
            'timestamp_column': 'created_at',     # 时间戳列名
        }
        
        # 运行状态
        self.running = False
        self.mysql_connection: Optional[mysql.connector.MySQLConnection] = None
        self.stream_manager_client: Optional[StreamManagerClient] = None
        self.last_sync_timestamps: Dict[str, datetime] = {}
        
        # 线程
        self.polling_thread: Optional[threading.Thread] = None
        self.status_monitor_thread: Optional[threading.Thread] = None
        
        logger.info("MySQL到S3轮询组件初始化完成")
    
    def setup_stream_manager(self) -> bool:
        """设置Stream Manager"""
        max_retries = 10
        retry_delay = 5
        
        for attempt in range(max_retries):
            try:
                logger.info(f"尝试连接Stream Manager (第{attempt + 1}次/共{max_retries}次)")
                
                # 创建Stream Manager客户端
                self.stream_manager_client = StreamManagerClient()
                logger.info("Stream Manager客户端创建成功")
                
                # 删除已存在的流（重新开始）
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
                
                # 创建S3导出配置
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
                
                # 创建状态流
                self.stream_manager_client.create_message_stream(
                    MessageStreamDefinition(
                        name=self.config['status_stream_name'],
                        strategy_on_full=StrategyOnFull.OverwriteOldestData
                    )
                )
                logger.info(f"成功创建状态流: {self.config['status_stream_name']}")
                
                # 创建带S3导出的消息流
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
    
    def setup_mysql_connection(self) -> bool:
        """设置MySQL连接"""
        try:
            logger.info(f"连接到MySQL数据库: {self.config['mysql_username']}@{self.config['mysql_host']}:{self.config['mysql_port']}")
            
            self.mysql_connection = mysql.connector.connect(
                host=self.config['mysql_host'],
                port=self.config['mysql_port'],
                database=self.config['mysql_database'],
                user=self.config['mysql_username'],
                password=self.config['mysql_password'],
                autocommit=True,
                charset='utf8mb4'
            )
            
            if self.mysql_connection.is_connected():
                logger.info("MySQL连接建立成功")
                
                # 初始化最后同步时间戳
                self.initialize_sync_timestamps()
                return True
            else:
                logger.error("MySQL连接失败")
                return False
                
        except Error as e:
            logger.error(f"MySQL连接错误: {e}")
            return False
    
    def execute_max_query_with_validation(self, table_name, column_name):
        """Execute MAX query with SQL-based validation using INFORMATION_SCHEMA"""
        try:
            cursor = self.mysql_connection.cursor()
            
            # SQL statement that validates table and column existence before executing the query
            validation_and_query_sql = """
            SET @table_exists = (
                SELECT COUNT(*) FROM information_schema.tables
                WHERE table_name = %s AND table_schema = DATABASE()
            );
            
            SET @column_exists = (
                SELECT COUNT(*) FROM information_schema.columns
                WHERE table_name = %s AND column_name = %s AND table_schema = DATABASE()
            );
            
            SET @sql = CASE 
                WHEN @table_exists > 0 AND @column_exists > 0 THEN
                    CONCAT('SELECT MAX(`', %s, '`) FROM `', %s, '`')
                ELSE
                    'SELECT NULL as validation_error'
            END;
            
            PREPARE stmt FROM @sql;
            EXECUTE stmt;
            DEALLOCATE PREPARE stmt;
            
            SELECT @table_exists as table_exists, @column_exists as column_exists;
            """
            
            # Execute the validation and query
            for result in cursor.execute(validation_and_query_sql, 
                                       (table_name, table_name, column_name, column_name, table_name), 
                                       multi=True):
                if result.with_rows:
                    rows = result.fetchall()
                    # The last result contains our validation flags
                    if len(rows) > 0 and len(rows[0]) == 2:
                        table_exists, column_exists = rows[0]
                        if table_exists == 0:
                            raise ValueError(f"Table does not exist: {table_name}")
                        if column_exists == 0:
                            raise ValueError(f"Column does not exist: {column_name} in table {table_name}")
                    else:
                        # This should be our MAX result
                        return rows[0][0] if rows and rows[0] else None
            
            cursor.close()
            return None
            
        except Error as e:
            logger.error(f"SQL validation and query error: {e}")
            raise

    def execute_incremental_query_with_validation(self, table_name, timestamp_column, last_timestamp, batch_size):
        """Execute incremental query with SQL-based validation using INFORMATION_SCHEMA"""
        try:
            cursor = self.mysql_connection.cursor(dictionary=True)
            
            # SQL statement that validates table and column existence before executing the query
            validation_and_query_sql = """
            SET @table_exists = (
                SELECT COUNT(*) FROM information_schema.tables
                WHERE table_name = %s AND table_schema = DATABASE()
            );
            
            SET @column_exists = (
                SELECT COUNT(*) FROM information_schema.columns
                WHERE table_name = %s AND column_name = %s AND table_schema = DATABASE()
            );
            
            SET @sql = CASE 
                WHEN @table_exists > 0 AND @column_exists > 0 THEN
                    CONCAT('SELECT * FROM `', %s, '` WHERE `', %s, '` > ? ORDER BY `', %s, '` ASC LIMIT ?')
                ELSE
                    'SELECT NULL as validation_error'
            END;
            
            PREPARE stmt FROM @sql;
            SET @last_timestamp = %s;
            SET @batch_size = %s;
            EXECUTE stmt USING @last_timestamp, @batch_size;
            DEALLOCATE PREPARE stmt;
            
            SELECT @table_exists as table_exists, @column_exists as column_exists;
            """
            
            # Execute the validation and query
            results = []
            validation_info = None
            
            for result in cursor.execute(validation_and_query_sql, 
                                       (table_name, table_name, timestamp_column, 
                                        table_name, timestamp_column, timestamp_column,
                                        last_timestamp, batch_size), 
                                       multi=True):
                if result.with_rows:
                    rows = result.fetchall()
                    if rows and len(rows[0]) == 2 and 'table_exists' in rows[0]:
                        # This is our validation result
                        validation_info = rows[0]
                    else:
                        # This is our data result
                        results = rows
            
            # Check validation results
            if validation_info:
                if validation_info['table_exists'] == 0:
                    raise ValueError(f"Table does not exist: {table_name}")
                if validation_info['column_exists'] == 0:
                    raise ValueError(f"Column does not exist: {timestamp_column} in table {table_name}")
            
            cursor.close()
            return results
            
        except Error as e:
            logger.error(f"SQL validation and incremental query error: {e}")
            raise

    def initialize_sync_timestamps(self):
        """初始化同步时间戳"""
        try:
            for table in self.config['monitored_tables']:
                # 获取表中最新记录的时间戳 - using SQL-based validation
                result = self.execute_max_query_with_validation(table, self.config['timestamp_column'])
                
                if result:
                    self.last_sync_timestamps[table] = result
                    logger.info(f"表 {table} 初始同步时间戳: {result}")
                else:
                    # 如果表为空，使用当前时间前1小时
                    self.last_sync_timestamps[table] = datetime.now() - timedelta(hours=1)
                    logger.info(f"表 {table} 使用默认同步时间戳: {self.last_sync_timestamps[table]}")
            
        except Exception as e:
            logger.error(f"初始化同步时间戳失败: {e}")
            # 使用默认时间戳
            for table in self.config['monitored_tables']:
                self.last_sync_timestamps[table] = datetime.now() - timedelta(hours=1)
    
    def poll_table_data(self, table_name: str) -> List[Dict[str, Any]]:
        """轮询表数据获取增量记录"""
        try:
            last_timestamp = self.last_sync_timestamps.get(table_name)
            if not last_timestamp:
                logger.warning(f"表 {table_name} 没有同步时间戳，跳过")
                return []

            # 查询增量数据 - using SQL-based validation
            records = self.execute_incremental_query_with_validation(
                table_name, 
                self.config['timestamp_column'], 
                last_timestamp, 
                self.config['batch_size']
            )
            
            if records:
                # 更新最后同步时间戳
                latest_timestamp = records[-1][self.config['timestamp_column']]
                self.last_sync_timestamps[table_name] = latest_timestamp
                
                logger.info(f"表 {table_name} 获取到 {len(records)} 条增量记录，最新时间戳: {latest_timestamp}")
            
            return records
            
        except Exception as e:
            logger.error(f"轮询表 {table_name} 数据失败: {e}")
            return []
    
    def process_and_send_data(self, table_name: str, records: List[Dict[str, Any]]) -> bool:
        """处理并发送数据到S3"""
        try:
            if not records:
                return True
            
            # 准备数据
            processed_data = {
                'source_type': 'mysql_polling',
                'table_name': table_name,
                'sync_timestamp': datetime.utcnow().isoformat() + 'Z',
                'record_count': len(records),
                'sync_range': {
                    'start_time': records[0][self.config['timestamp_column']].isoformat() if records[0][self.config['timestamp_column']] else None,
                    'end_time': records[-1][self.config['timestamp_column']].isoformat() if records[-1][self.config['timestamp_column']] else None
                },
                'records': []
            }
            
            # 处理每条记录
            for record in records:
                # 转换特殊类型对象为JSON可序列化的格式
                processed_record = {}
                for key, value in record.items():
                    if isinstance(value, datetime):
                        processed_record[key] = value.isoformat()
                    elif isinstance(value, Decimal):
                        processed_record[key] = float(value)
                    elif value is None:
                        processed_record[key] = None
                    else:
                        processed_record[key] = value
                processed_data['records'].append(processed_record)
            
            # 生成S3键名
            timestamp_str = datetime.utcnow().strftime('%Y/%m/%d/%H%M%S')
            s3_key = f"{self.config['s3_key_prefix']}{timestamp_str}_{table_name}_polling.json"
            
            # 创建临时文件
            import tempfile
            with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as temp_file:
                json.dump(processed_data, temp_file, indent=2)
                temp_file_path = temp_file.name
            
            # 创建S3导出任务
            s3_export_task = S3ExportTaskDefinition(
                bucket=self.config['s3_bucket'],
                key=s3_key,
                input_url=f"file:{temp_file_path}"
            )
            
            # 发送到Stream Manager
            sequence_number = self.stream_manager_client.append_message(
                self.config['stream_name'],
                Util.validate_and_serialize_to_json_bytes(s3_export_task)
            )
            
            logger.info(f"成功提交S3导出任务: {table_name} ({len(records)}条记录) -> s3://{self.config['s3_bucket']}/{s3_key}")
            logger.info(f"Stream Manager序列号: {sequence_number}")
            logger.info(f"临时文件保留供Stream Manager处理: {temp_file_path}")
            
            return True
            
        except Exception as e:
            logger.error(f"处理并发送数据失败 {table_name}: {e}")
            return False
    
    def monitor_s3_export_status(self):
        """监控S3导出状态"""
        while self.running:
            try:
                if not self.stream_manager_client:
                    time.sleep(5)
                    continue
                
                # 读取状态流消息
                messages = self.stream_manager_client.read_messages(
                    self.config['status_stream_name'],
                    ReadMessagesOptions(min_message_count=1, read_timeout_millis=1000)
                )
                
                for message in messages:
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
    
    def polling_loop(self):
        """轮询循环"""
        while self.running:
            try:
                logger.info("开始MySQL数据轮询...")
                
                # 检查MySQL连接
                if not self.mysql_connection or not self.mysql_connection.is_connected():
                    logger.warning("MySQL连接断开，尝试重连...")
                    if not self.setup_mysql_connection():
                        logger.error("MySQL重连失败，等待下次轮询")
                        time.sleep(self.config['polling_interval'])
                        continue
                
                # 轮询每个监控的表
                total_records = 0
                for table_name in self.config['monitored_tables']:
                    if not self.running:
                        break
                    
                    records = self.poll_table_data(table_name)
                    if records:
                        success = self.process_and_send_data(table_name, records)
                        if success:
                            total_records += len(records)
                            logger.info(f"表 {table_name} 处理成功: {len(records)} 条记录")
                        else:
                            logger.error(f"表 {table_name} 处理失败")
                
                if total_records > 0:
                    logger.info(f"本轮轮询完成，共处理 {total_records} 条记录")
                else:
                    logger.debug("本轮轮询无新数据")
                
            except Exception as e:
                logger.error(f"轮询循环出错: {e}")
            
            # 等待下次轮询
            logger.info(f"等待 {self.config['polling_interval']} 秒后进行下次轮询...")
            time.sleep(self.config['polling_interval'])
    
    def start(self):
        """启动组件"""
        logger.info("启动MySQL到S3轮询组件...")
        
        # 设置Stream Manager
        if not self.setup_stream_manager():
            raise Exception("Stream Manager设置失败")
        
        # 设置MySQL连接
        if not self.setup_mysql_connection():
            raise Exception("MySQL连接设置失败")
        
        # 启动运行标志
        self.running = True
        
        # 启动轮询线程
        self.polling_thread = threading.Thread(target=self.polling_loop, daemon=True)
        self.polling_thread.start()
        logger.info("轮询线程已启动")
        
        # 启动状态监控线程
        self.status_monitor_thread = threading.Thread(target=self.monitor_s3_export_status, daemon=True)
        self.status_monitor_thread.start()
        logger.info("状态监控线程已启动")
        
        logger.info("MySQL到S3轮询组件启动完成")
    
    def stop(self):
        """停止组件"""
        logger.info("停止MySQL到S3轮询组件...")
        
        self.running = False
        
        # 等待线程结束
        if self.polling_thread and self.polling_thread.is_alive():
            self.polling_thread.join(timeout=10)
        
        if self.status_monitor_thread and self.status_monitor_thread.is_alive():
            self.status_monitor_thread.join(timeout=10)
        
        # 关闭连接
        if self.mysql_connection and self.mysql_connection.is_connected():
            self.mysql_connection.close()
        
        if self.stream_manager_client:
            self.stream_manager_client.close()
        
        logger.info("MySQL到S3轮询组件已停止")
    
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
    logger.info("启动MySQL到S3轮询组件")
    
    component = MySQLToS3Component()
    
    try:
        component.run()
    except Exception as e:
        logger.error(f"组件启动失败: {e}")
        raise

if __name__ == "__main__":
    main()
