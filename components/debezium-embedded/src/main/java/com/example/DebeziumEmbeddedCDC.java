package com.example;

// Debezium imports
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import io.debezium.config.Configuration;
import io.debezium.embedded.Connect;
import io.debezium.engine.DebeziumEngine;
import io.debezium.engine.RecordChangeEvent;
import io.debezium.engine.format.ChangeEventFormat;
import org.apache.kafka.connect.source.SourceRecord;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

// Stream Manager imports - 按照GitHub示例
import com.amazonaws.greengrass.streammanager.client.StreamManagerClient;
import com.amazonaws.greengrass.streammanager.client.StreamManagerClientFactory;
import com.amazonaws.greengrass.streammanager.client.exception.ResourceNotFoundException;
import com.amazonaws.greengrass.streammanager.client.exception.StreamManagerException;
import com.amazonaws.greengrass.streammanager.client.utils.ValidateAndSerialize;
import com.amazonaws.greengrass.streammanager.model.Message;
import com.amazonaws.greengrass.streammanager.model.MessageStreamDefinition;
import com.amazonaws.greengrass.streammanager.model.ReadMessagesOptions;
import com.amazonaws.greengrass.streammanager.model.S3ExportTaskDefinition;
import com.amazonaws.greengrass.streammanager.model.Status;
import com.amazonaws.greengrass.streammanager.model.StatusConfig;
import com.amazonaws.greengrass.streammanager.model.StatusLevel;
import com.amazonaws.greengrass.streammanager.model.StatusMessage;
import com.amazonaws.greengrass.streammanager.model.StrategyOnFull;
import com.amazonaws.greengrass.streammanager.model.export.ExportDefinition;
import com.amazonaws.greengrass.streammanager.model.export.S3ExportTaskExecutorConfig;
import com.amazonaws.services.lambda.runtime.Context;

// Java standard imports
import java.time.Instant;
import java.util.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

import java.io.*;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Debezium Embedded CDC Component for AWS IoT Greengrass v2
 * 按照GitHub示例 https://github.com/aws-greengrass/aws-greengrass-stream-manager-sdk-java/tree/main/samples/StreamManagerS3
 * 整体流程: MySQL > Debezium Embedded Component > Stream Manager Component > S3
 * 
 * @author IoT Project Team
 * @version 1.0.0
 */
public class DebeziumEmbeddedCDC {
    
    private static final Logger logger = LoggerFactory.getLogger(DebeziumEmbeddedCDC.class);
    
    // Configuration constants - 沿用deploy.sh中的配置
    private static final String STREAM_NAME = "DebeziumEmbeddedDataStream_ab";
    private static final String STATUS_STREAM_NAME = STREAM_NAME + "_Status";
    private static final String S3_BUCKET = "zihangh-gg-streammanager-poc";
    private static final String S3_KEY_PREFIX = "gg_mysql/debezium-embedded/";
    private static final int BATCH_SIZE = 5;  // 减小批次大小，更快触发发送
    private static final int BATCH_TIMEOUT_SECONDS = 10;  // 减少超时时间
    
    // Core components
    private DebeziumEngine<RecordChangeEvent<SourceRecord>> engine;
    private StreamManagerClient streamManagerClient;
    private final ObjectMapper objectMapper;
    private final AtomicBoolean running = new AtomicBoolean(false);
    
    // Batch processing
    private final List<Map<String, Object>> eventBuffer = new ArrayList<>();
    private final Object bufferLock = new Object();
    private long lastBatchTime = System.currentTimeMillis();
    private int sequenceNumber = 0;
    
    // Executor for async processing
    private final ScheduledExecutorService scheduler = Executors.newScheduledThreadPool(2);
    
    /**
     * Lambda handler - 按照GitHub示例添加
     */
    public String handleRequest(Object input, Context context) {
        return "Debezium Embedded CDC Component for ab Project";
    }
    
    public DebeziumEmbeddedCDC() {
        this.objectMapper = new ObjectMapper();
        this.objectMapper.registerModule(new JavaTimeModule());
    }
    
    /**
     * Main entry point
     */
    public static void main(String[] args) {
        DebeziumEmbeddedCDC cdc = new DebeziumEmbeddedCDC();
        
        // Add shutdown hook
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            logger.info("收到关闭信号，正在优雅关闭...");
            cdc.stop();
        }));
        
        try {
            cdc.start();
        } catch (Exception e) {
            logger.error("启动Debezium Embedded CDC组件失败", e);
            System.exit(1);
        }
    }
    
    /**
     * Start the CDC component
     */
    public void start() throws Exception {
        logger.info("启动Debezium Embedded CDC组件...");
        
        // Initialize Stream Manager client
        initializeStreamManager();
        
        // Create streams
        createStreams();
        
        // Load Debezium configuration
        Configuration config = loadDebeziumConfiguration();
        
        // Create and start Debezium engine
        engine = DebeziumEngine.create(ChangeEventFormat.of(Connect.class))
                .using(config.asProperties())
                .notifying(this::handleChangeEvent)
                .build();
        
        running.set(true);
        
        // Start batch timeout scheduler
        scheduler.scheduleAtFixedRate(this::checkBatchTimeout, 
                BATCH_TIMEOUT_SECONDS, BATCH_TIMEOUT_SECONDS, TimeUnit.SECONDS);
        
        // Start S3 export status monitoring - 按照GitHub示例
        monitorS3ExportStatus();
        
        // Start engine in separate thread
        ExecutorService executor = Executors.newSingleThreadExecutor();
        executor.execute(() -> {
            try {
                logger.info("Debezium引擎启动成功，开始监听MySQL变更事件...");
                engine.run();
            } catch (Exception e) {
                logger.error("Debezium引擎运行异常", e);
            }
        });
        
        // Send startup status
        sendStatusMessage("STARTED", "Debezium Embedded CDC组件启动成功");
        
        // Keep main thread alive
        try {
            while (running.get()) {
                Thread.sleep(1000);
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        
        executor.shutdown();
    }
    
    /**
     * Stop the CDC component
     */
    public void stop() {
        if (!running.compareAndSet(true, false)) {
            return;
        }
        
        logger.info("正在停止Debezium Embedded CDC组件...");
        
        try {
            // Send remaining events
            synchronized (bufferLock) {
                if (!eventBuffer.isEmpty()) {
                    logger.info("发送剩余的{}个CDC事件...", eventBuffer.size());
                    sendBatchToS3();
                }
            }
            
            // Stop engine
            if (engine != null) {
                engine.close();
            }
            
            // Shutdown scheduler
            scheduler.shutdown();
            try {
                if (!scheduler.awaitTermination(10, TimeUnit.SECONDS)) {
                    scheduler.shutdownNow();
                }
            } catch (InterruptedException e) {
                scheduler.shutdownNow();
                Thread.currentThread().interrupt();
            }
            
            // Close Stream Manager client - 按照GitHub示例
            if (streamManagerClient != null) {
                streamManagerClient.close();
            }
            
            sendStatusMessage("STOPPED", "Debezium Embedded CDC组件已停止");
            logger.info("Debezium Embedded CDC组件已成功停止");
            
        } catch (Exception e) {
            logger.error("停止组件时发生错误", e);
        }
    }
    
    /**
     * Initialize Stream Manager client - 按照GitHub示例，添加重试逻辑
     */
    private void initializeStreamManager() throws Exception {
        int maxRetries = 10;
        int retryDelay = 5000; // 5秒
        
        for (int attempt = 1; attempt <= maxRetries; attempt++) {
            try {
                logger.info("尝试连接Stream Manager (第{}次/共{}次)...", attempt, maxRetries);
                
                // Create Stream Manager client - 按照GitHub示例
                streamManagerClient = StreamManagerClientFactory.standard().build();
                logger.info("Stream Manager客户端初始化成功");
                return;
                
            } catch (Exception e) {
                logger.warn("Stream Manager连接失败 (第{}次/共{}次): {}", attempt, maxRetries, e.getMessage());
                
                if (attempt == maxRetries) {
                    logger.error("Stream Manager连接重试{}次后仍然失败", maxRetries);
                    throw e;
                }
                
                try {
                    logger.info("等待{}毫秒后重试...", retryDelay);
                    Thread.sleep(retryDelay);
                } catch (InterruptedException ie) {
                    Thread.currentThread().interrupt();
                    throw new RuntimeException("连接重试被中断", ie);
                }
            }
        }
    }
    
    /**
     * Create required streams - 按照GitHub示例
     */
    private void createStreams() {
        try {
            // Try deleting the status stream (if it exists) so that we have a fresh start - 严格按照GitHub示例
            try {
                streamManagerClient.deleteMessageStream(STATUS_STREAM_NAME);
            } catch (ResourceNotFoundException ignored) {
            }

            // Try deleting the stream (if it exists) so that we have a fresh start - 严格按照GitHub示例
            try {
                streamManagerClient.deleteMessageStream(STREAM_NAME);
            } catch (ResourceNotFoundException ignored) {
            }

            // 严格按照GitHub示例创建ExportDefinition
            final ExportDefinition exports = new ExportDefinition()
                    .withS3TaskExecutor(new ArrayList<S3ExportTaskExecutorConfig>() {{
                        add(new S3ExportTaskExecutorConfig()
                                .withIdentifier("S3Export" + STREAM_NAME) // Required
                                // Optional. Add an export status stream to add statuses for all S3 upload tasks.
                                .withStatusConfig(new StatusConfig()
                                        .withStatusLevel(StatusLevel.INFO) // Default is INFO level statuses.
                                        // Status Stream should be created before specifying in S3 Export Config.
                                        .withStatusStreamName(STATUS_STREAM_NAME)));
                    }});

            // Create the export status stream first - 严格按照GitHub示例
            streamManagerClient.createMessageStream(
                    new MessageStreamDefinition()
                            .withName(STATUS_STREAM_NAME)
                            .withStrategyOnFull(StrategyOnFull.OverwriteOldestData));
            
            logger.info("成功创建状态流: {}", STATUS_STREAM_NAME);

            // Then create the stream with the S3 Export definition - 严格按照GitHub示例
            streamManagerClient.createMessageStream(
                    new MessageStreamDefinition()
                            .withName(STREAM_NAME)
                            .withStrategyOnFull(StrategyOnFull.OverwriteOldestData)
                            .withExportDefinition(exports));
            
            logger.info("成功创建数据流: {} with S3 export definition", STREAM_NAME);
            
        } catch (Exception e) {
            logger.error("创建数据流失败", e);
            throw new RuntimeException("Failed to create streams", e);
        }
    }
    
    /**
     * Load Debezium configuration from properties file
     */
    private Configuration loadDebeziumConfiguration() throws IOException {
        Properties props = new Properties();
        
        // Load from properties file
        File configFile = new File("debezium.properties");
        if (configFile.exists()) {
            try (FileInputStream fis = new FileInputStream(configFile)) {
                props.load(fis);
                logger.info("从配置文件加载Debezium配置: {}", configFile.getAbsolutePath());
            }
        } else {
            logger.warn("配置文件不存在，使用默认配置: {}", configFile.getAbsolutePath());
            // Use default configuration if file doesn't exist
            setDefaultConfiguration(props);
        }
        
        // Override with environment variables if present
        overrideWithEnvironmentVariables(props);
        
        return Configuration.from(props);
    }
    
    /**
     * Set default Debezium configuration
     */
    private void setDefaultConfiguration(Properties props) {
        props.setProperty("name", "debezium-embedded-mysql-connector");
        props.setProperty("connector.class", "io.debezium.connector.mysql.MySqlConnector");
        props.setProperty("database.hostname", "localhost");
        props.setProperty("database.port", "3306");
        props.setProperty("database.user", "testuser");
        props.setProperty("database.password", "testpassword");
        props.setProperty("database.server.id", "3001");
        props.setProperty("database.include.list", "testdb");
        props.setProperty("table.include.list", "testdb.sensor_data");
        props.setProperty("topic.prefix", "ab-mysql-embedded");
        props.setProperty("schema.history.internal", "io.debezium.storage.file.history.FileSchemaHistory");
        props.setProperty("schema.history.internal.file.filename", "/tmp/debezium-schema-history.dat");
        props.setProperty("offset.storage", "org.apache.kafka.connect.storage.FileOffsetBackingStore");
        props.setProperty("offset.storage.file.filename", "/tmp/debezium-offsets.dat");
        props.setProperty("offset.flush.interval.ms", "10000");
    }
    
    /**
     * Override configuration with environment variables
     */
    private void overrideWithEnvironmentVariables(Properties props) {
        Map<String, String> envOverrides = Map.of(
            "MYSQL_HOST", "database.hostname",
            "MYSQL_PORT", "database.port", 
            "MYSQL_USER", "database.user",
            "MYSQL_PASSWORD", "database.password",
            "MYSQL_DATABASE", "database.include.list"
        );
        
        envOverrides.forEach((envVar, propKey) -> {
            String envValue = System.getenv(envVar);
            if (envValue != null && !envValue.trim().isEmpty()) {
                props.setProperty(propKey, envValue);
                logger.info("使用环境变量覆盖配置: {} = {}", propKey, envValue);
            }
        });
    }
    
    /**
     * Handle change events from Debezium
     */
    private void handleChangeEvent(RecordChangeEvent<SourceRecord> event) {
        try {
            SourceRecord record = event.record();
            
            // Skip if no value (tombstone)
            if (record.value() == null) {
                return;
            }
            
            // Parse the change event
            Map<String, Object> cdcEvent = parseChangeEvent(record);
            if (cdcEvent != null) {
                synchronized (bufferLock) {
                    eventBuffer.add(cdcEvent);
                    
                    // Check if we should send batch
                    if (eventBuffer.size() >= BATCH_SIZE) {
                        sendBatchToS3();
                    }
                }
                
                String eventType = (String) cdcEvent.get("event_type");
                String table = (String) cdcEvent.get("table");
                logger.info("处理{}事件: {}, 缓冲区大小: {}", eventType, table, eventBuffer.size());
            }
            
        } catch (Exception e) {
            logger.error("处理变更事件失败", e);
        }
    }
    
    /**
     * Parse Debezium change event into our format
     */
    private Map<String, Object> parseChangeEvent(SourceRecord record) {
        try {
            // Get the value as Struct (Debezium format)
            Object recordValue = record.value();
            if (recordValue == null) {
                return null;
            }
            
            // Convert Struct to Map for easier processing
            Map<String, Object> valueMap = convertStructToMap(recordValue);
            
            // Extract operation type
            String operation = (String) valueMap.get("op");
            if (operation == null || operation.isEmpty()) {
                return null; // Skip schema change events
            }
            
            // Create our CDC event format
            Map<String, Object> cdcEvent = new HashMap<>();
            cdcEvent.put("event_type", mapOperationType(operation));
            cdcEvent.put("timestamp", Instant.now().toString());
            
            // Extract source information
            Map<String, Object> source = (Map<String, Object>) valueMap.get("source");
            if (source != null) {
                cdcEvent.put("schema", source.get("db"));
                cdcEvent.put("table", source.get("table"));
                
                // Binlog position info
                Map<String, Object> binlogPosition = new HashMap<>();
                binlogPosition.put("file", source.get("file"));
                binlogPosition.put("position", source.get("pos"));
                binlogPosition.put("server_id", source.get("server_id"));
                cdcEvent.put("binlog_position", binlogPosition);
            }
            
            // Extract before/after data
            Map<String, Object> before = (Map<String, Object>) valueMap.get("before");
            Map<String, Object> after = (Map<String, Object>) valueMap.get("after");
            
            if (before != null) {
                cdcEvent.put("before", before);
            }
            if (after != null) {
                cdcEvent.put("after", after);
            }
            
            return cdcEvent;
            
        } catch (Exception e) {
            logger.error("解析变更事件失败", e);
            return null;
        }
    }
    
    /**
     * Convert Kafka Connect Struct to Map
     */
    private Map<String, Object> convertStructToMap(Object obj) {
        if (obj == null) {
            return null;
        }
        
        if (obj instanceof org.apache.kafka.connect.data.Struct) {
            org.apache.kafka.connect.data.Struct struct = (org.apache.kafka.connect.data.Struct) obj;
            Map<String, Object> map = new HashMap<>();
            
            for (org.apache.kafka.connect.data.Field field : struct.schema().fields()) {
                Object value = struct.get(field);
                if (value instanceof org.apache.kafka.connect.data.Struct) {
                    map.put(field.name(), convertStructToMap(value));
                } else {
                    map.put(field.name(), value);
                }
            }
            return map;
        }
        
        return (Map<String, Object>) obj;
    }
    
    /**
     * Map Debezium operation type to our event type
     */
    private String mapOperationType(String operation) {
        switch (operation.toLowerCase()) {
            case "c":
            case "create":
                return "INSERT";
            case "u":
            case "update":
                return "UPDATE";
            case "d":
            case "delete":
                return "DELETE";
            default:
                return null; // Skip unsupported operations
        }
    }
    
    /**
     * Check batch timeout and send if needed
     */
    private void checkBatchTimeout() {
        synchronized (bufferLock) {
            if (!eventBuffer.isEmpty() && 
                (System.currentTimeMillis() - lastBatchTime) >= (BATCH_TIMEOUT_SECONDS * 1000)) {
                logger.info("批次超时，发送{}个事件到S3", eventBuffer.size());
                sendBatchToS3();
            }
        }
    }
    
    /**
     * Send batch of events to S3 via Stream Manager - 按照GitHub示例
     */
    private void sendBatchToS3() {
        if (eventBuffer.isEmpty()) {
            return;
        }
        
        try {
            // Create batch data
            Map<String, Object> batchData = new HashMap<>();
            batchData.put("batch_timestamp", Instant.now().toString());
            batchData.put("source", "debezium-embedded-cdc");
            batchData.put("event_count", eventBuffer.size());
            batchData.put("events", new ArrayList<>(eventBuffer));
            
            // Write to temporary file first (as required by S3ExportTaskDefinition)
            String fileName = String.format("cdc_events_%s_%d.json", 
                    Instant.now().toString().replace(":", "-"), sequenceNumber);
            String localFilePath = "/tmp/" + fileName;
            
            // Write JSON data to local file
            String jsonString = objectMapper.writeValueAsString(batchData);
            try (java.io.FileWriter writer = new java.io.FileWriter(localFilePath)) {
                writer.write(jsonString);
            }
            
            // Create S3 export task definition - 严格按照GitHub示例
            S3ExportTaskDefinition s3ExportTaskDefinition = new S3ExportTaskDefinition()
                    .withBucket(S3_BUCKET)
                    .withKey(S3_KEY_PREFIX + fileName)
                    .withInputUrl("file:" + localFilePath);
            
            // Send S3 export task to Stream Manager - 严格按照GitHub示例
            long sequenceNum = streamManagerClient.appendMessage(STREAM_NAME,
                    ValidateAndSerialize.validateAndSerializeToJsonBytes(s3ExportTaskDefinition));
            
            logger.info("成功提交S3导出任务到Stream Manager，事件数: {}, 序列号: {}", eventBuffer.size(), sequenceNum);
            logger.info("S3位置: s3://{}/{}", S3_BUCKET, S3_KEY_PREFIX + fileName);
            logger.info("本地文件: {}", localFilePath);
            
            // Clear buffer and update timestamp
            eventBuffer.clear();
            lastBatchTime = System.currentTimeMillis();
            sequenceNumber++;
            
            // Send success status
            sendStatusMessage("BATCH_SENT", 
                    String.format("成功发送S3导出任务 #%d，包含 %d 个事件", sequenceNumber, eventBuffer.size()));
            
        } catch (Exception e) {
            logger.error("发送S3导出任务失败", e);
            sendStatusMessage("ERROR", "发送S3导出任务失败: " + e.getMessage());
        }
    }
    
    /**
     * Monitor S3 export status continuously - 严格按照GitHub示例
     */
    private void monitorS3ExportStatus() {
        scheduler.scheduleAtFixedRate(() -> {
            try {
                // Read the statuses from the export status stream - 严格按照GitHub示例
                List<Message> messages = streamManagerClient.readMessages(STATUS_STREAM_NAME,
                        new ReadMessagesOptions().withMinMessageCount(1L).withReadTimeoutMillis(1000L));
                
                for (Message message : messages) {
                    // Deserialize the status message first - 严格按照GitHub示例
                    StatusMessage statusMessage = ValidateAndSerialize.deserializeJsonBytesToObj(
                            message.getPayload(), StatusMessage.class);
                    
                    // Check the status of the status message - 严格按照GitHub示例
                    if (Status.Success.equals(statusMessage.getStatus())) {
                        logger.info("✅ Successfully uploaded file at path {} to S3", 
                                statusMessage.getStatusContext().getS3ExportTaskDefinition().getInputUrl());
                    } else if (Status.Failure.equals(statusMessage.getStatus()) || 
                               Status.Canceled.equals(statusMessage.getStatus())) {
                        logger.error("❌ Unable to upload file at path {} to S3. Message: {}", 
                                statusMessage.getStatusContext().getS3ExportTaskDefinition().getInputUrl(),
                                statusMessage.getMessage());
                    } else if (Status.InProgress.equals(statusMessage.getStatus())) {
                        logger.info("⏳ S3 upload in progress for file: {}", 
                                statusMessage.getStatusContext().getS3ExportTaskDefinition().getInputUrl());
                    }
                }
            } catch (Exception e) {
                // 按照GitHub示例，忽略StreamManagerException
                logger.debug("读取状态流时出错: {}", e.getMessage());
            }
        }, 5, 5, TimeUnit.SECONDS); // 按照GitHub示例，每5秒检查一次
    }
    private void sendStatusMessage(String status, String message) {
        try {
            Map<String, Object> statusData = new HashMap<>();
            statusData.put("timestamp", Instant.now().toString());
            statusData.put("component", "DebeziumEmbeddedCDC");
            statusData.put("status", status);
            statusData.put("message", message);
            statusData.put("sequence_number", sequenceNumber);
            statusData.put("buffer_size", eventBuffer.size());
            
            // 直接使用ObjectMapper序列化，避免ValidateAndSerialize的类型问题
            String jsonString = objectMapper.writeValueAsString(statusData);
            byte[] jsonData = jsonString.getBytes("UTF-8");
            
            // Send to Stream Manager - 按照GitHub示例
            streamManagerClient.appendMessage(STATUS_STREAM_NAME, jsonData);
            
        } catch (Exception e) {
            // 只记录警告，不抛出异常，避免影响主流程
            logger.warn("发送状态消息失败: {}", e.getMessage());
        }
    }
}
