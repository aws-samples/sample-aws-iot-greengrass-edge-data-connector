-- IoT Greengrass CDC 解决方案 - MySQL初始化脚本
-- =====================================================

-- 创建数据库
CREATE DATABASE IF NOT EXISTS testdb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- 使用数据库
USE testdb;

-- 创建用户（如果不存在）
CREATE USER IF NOT EXISTS 'testuser'@'%' IDENTIFIED BY 'testpassword';
CREATE USER IF NOT EXISTS 'testuser'@'localhost' IDENTIFIED BY 'testpassword';

-- 授予权限
GRANT ALL PRIVILEGES ON testdb.* TO 'testuser'@'%';
GRANT ALL PRIVILEGES ON testdb.* TO 'testuser'@'localhost';

-- 刷新权限
FLUSH PRIVILEGES;

-- 创建传感器数据表
CREATE TABLE IF NOT EXISTS sensor_data (
    id INT AUTO_INCREMENT PRIMARY KEY,
    sensor_name VARCHAR(100) NOT NULL,
    temperature DECIMAL(5,2),
    humidity DECIMAL(5,2),
    pressure DECIMAL(7,2),
    location VARCHAR(200),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_sensor_name (sensor_name),
    INDEX idx_created_at (created_at),
    INDEX idx_updated_at (updated_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 创建设备状态表
CREATE TABLE IF NOT EXISTS device_status (
    id INT AUTO_INCREMENT PRIMARY KEY,
    device_id VARCHAR(50) NOT NULL UNIQUE,
    device_name VARCHAR(100) NOT NULL,
    status ENUM('online', 'offline', 'maintenance') DEFAULT 'offline',
    last_heartbeat TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_device_id (device_id),
    INDEX idx_status (status),
    INDEX idx_last_heartbeat (last_heartbeat)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 创建事件日志表
CREATE TABLE IF NOT EXISTS event_log (
    id INT AUTO_INCREMENT PRIMARY KEY,
    event_type VARCHAR(50) NOT NULL,
    event_source VARCHAR(100) NOT NULL,
    event_data JSON,
    severity ENUM('info', 'warning', 'error', 'critical') DEFAULT 'info',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_event_type (event_type),
    INDEX idx_event_source (event_source),
    INDEX idx_severity (severity),
    INDEX idx_created_at (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 插入初始测试数据
INSERT INTO sensor_data (sensor_name, temperature, humidity, pressure, location) VALUES
('Temperature_Sensor_01', 23.5, 45.2, 1013.25, 'Building A - Floor 1'),
('Temperature_Sensor_02', 24.1, 48.7, 1012.80, 'Building A - Floor 2'),
('Humidity_Sensor_01', 22.8, 52.3, 1014.10, 'Building B - Floor 1'),
('Pressure_Sensor_01', 25.2, 41.8, 1015.45, 'Building C - Roof'),
('Multi_Sensor_01', 23.9, 46.5, 1013.75, 'Warehouse - Zone A');

INSERT INTO device_status (device_id, device_name, status, last_heartbeat) VALUES
('DEV001', 'Greengrass Core Device 01', 'online', NOW()),
('DEV002', 'Edge Gateway 01', 'online', NOW()),
('DEV003', 'Sensor Hub 01', 'offline', DATE_SUB(NOW(), INTERVAL 1 HOUR)),
('DEV004', 'Data Collector 01', 'maintenance', NOW());

INSERT INTO event_log (event_type, event_source, event_data, severity) VALUES
('system_start', 'greengrass_core', '{"component": "debezium", "version": "1.0.6"}', 'info'),
('data_sync', 'mysql_poller', '{"table": "sensor_data", "records": 5}', 'info'),
('connection_error', 'sftp_client', '{"host": "localhost", "error": "timeout"}', 'warning'),
('component_restart', 'stream_manager', '{"reason": "memory_limit", "restart_count": 1}', 'error');

-- 启用binlog（如果尚未启用）
-- 注意：这些设置通常需要在MySQL配置文件中设置并重启MySQL服务
-- SET GLOBAL log_bin = ON;
-- SET GLOBAL binlog_format = 'ROW';
-- SET GLOBAL binlog_row_image = 'FULL';

-- 创建存储过程用于生成测试数据
DELIMITER //

CREATE PROCEDURE IF NOT EXISTS GenerateTestData(IN record_count INT)
BEGIN
    DECLARE i INT DEFAULT 1;
    DECLARE sensor_names TEXT DEFAULT 'Temperature_Sensor,Humidity_Sensor,Pressure_Sensor,Multi_Sensor,Air_Quality_Sensor';
    DECLARE locations TEXT DEFAULT 'Building A - Floor 1,Building A - Floor 2,Building B - Floor 1,Building C - Roof,Warehouse - Zone A,Parking Lot,Server Room,Conference Room';
    DECLARE sensor_name VARCHAR(100);
    DECLARE location VARCHAR(200);
    
    WHILE i <= record_count DO
        SET sensor_name = CONCAT(
            SUBSTRING_INDEX(SUBSTRING_INDEX(sensor_names, ',', FLOOR(1 + RAND() * 5)), ',', -1),
            '_',
            LPAD(FLOOR(1 + RAND() * 99), 2, '0')
        );
        
        SET location = SUBSTRING_INDEX(SUBSTRING_INDEX(locations, ',', FLOOR(1 + RAND() * 8)), ',', -1);
        
        INSERT INTO sensor_data (sensor_name, temperature, humidity, pressure, location) VALUES (
            sensor_name,
            ROUND(15 + RAND() * 20, 2),  -- 温度: 15-35°C
            ROUND(30 + RAND() * 40, 2),  -- 湿度: 30-70%
            ROUND(1000 + RAND() * 30, 2), -- 气压: 1000-1030 hPa
            location
        );
        
        SET i = i + 1;
    END WHILE;
END //

DELIMITER ;

-- 创建清理旧数据的存储过程
DELIMITER //

CREATE PROCEDURE IF NOT EXISTS CleanOldData(IN days_to_keep INT)
BEGIN
    DECLARE rows_deleted INT DEFAULT 0;
    
    -- 清理旧的传感器数据
    DELETE FROM sensor_data WHERE created_at < DATE_SUB(NOW(), INTERVAL days_to_keep DAY);
    SET rows_deleted = ROW_COUNT();
    
    -- 清理旧的事件日志
    DELETE FROM event_log WHERE created_at < DATE_SUB(NOW(), INTERVAL days_to_keep DAY);
    SET rows_deleted = rows_deleted + ROW_COUNT();
    
    -- 记录清理操作
    INSERT INTO event_log (event_type, event_source, event_data, severity) VALUES (
        'data_cleanup',
        'mysql_maintenance',
        JSON_OBJECT('days_to_keep', days_to_keep, 'rows_deleted', rows_deleted),
        'info'
    );
    
    SELECT CONCAT('Cleaned ', rows_deleted, ' old records') AS result;
END //

DELIMITER ;

-- 创建视图用于监控
CREATE OR REPLACE VIEW sensor_data_summary AS
SELECT 
    DATE(created_at) as date,
    COUNT(*) as total_records,
    COUNT(DISTINCT sensor_name) as unique_sensors,
    AVG(temperature) as avg_temperature,
    AVG(humidity) as avg_humidity,
    AVG(pressure) as avg_pressure,
    MIN(created_at) as first_record,
    MAX(created_at) as last_record
FROM sensor_data 
GROUP BY DATE(created_at)
ORDER BY date DESC;

CREATE OR REPLACE VIEW device_status_summary AS
SELECT 
    status,
    COUNT(*) as device_count,
    GROUP_CONCAT(device_name SEPARATOR ', ') as devices
FROM device_status 
GROUP BY status;

-- 显示初始化完成信息
SELECT 'MySQL数据库初始化完成' as message;
SELECT 'Tables created:' as info, COUNT(*) as count FROM information_schema.tables WHERE table_schema = 'testdb';
SELECT 'Initial sensor records:' as info, COUNT(*) as count FROM sensor_data;
SELECT 'Initial device records:' as info, COUNT(*) as count FROM device_status;
SELECT 'Initial event records:' as info, COUNT(*) as count FROM event_log;

-- 显示binlog状态
SHOW VARIABLES LIKE 'log_bin';
SHOW VARIABLES LIKE 'binlog_format';
SHOW VARIABLES LIKE 'binlog_row_image';
