import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.clients.admin.*;

import java.util.Collections;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.Properties;
import java.util.concurrent.TimeUnit;

public class ProduceMessages {
    public static void main(String[] args) throws Exception {
        Properties props = new Properties();
        props.put("bootstrap.servers", "kafka:9092");
        props.put("key.serializer", "org.apache.kafka.common.serialization.StringSerializer");
        props.put("value.serializer", "org.apache.kafka.common.serialization.StringSerializer");

        String acks = System.getenv().getOrDefault("ACKS", "1");
        props.put("acks", acks);

        // 10MB payload 대비 여유
        props.put("max.request.size", "15000000");

        long requestTimeoutMs = Long.parseLong(
            System.getenv().getOrDefault("REQUEST_TIMEOUT_MS", "15000")
        );
        long deliveryTimeoutMs = Long.parseLong(
            System.getenv().getOrDefault("DELIVERY_TIMEOUT_MS", "30000")
        );
        long maxBlockMs = Long.parseLong(
            System.getenv().getOrDefault("MAX_BLOCK_MS", "15000")
        );
        long sendAckTimeoutMs = Long.parseLong(
            System.getenv().getOrDefault("SEND_ACK_TIMEOUT_MS", "15000")
        );

        props.put("request.timeout.ms", Long.toString(requestTimeoutMs));
        props.put("delivery.timeout.ms", Long.toString(deliveryTimeoutMs));
        props.put("max.block.ms", Long.toString(maxBlockMs));

        String largeValue = "x".repeat(10_000_000) + "\n"; // 10MB 메시지

        String runDir = "/profiles/run";
        Path metricsPath = Path.of(runDir, "metrics.txt");

        System.out.println("producer_start payload_bytes=" + largeValue.length()
            + " acks=" + acks
            + " request_timeout_ms=" + requestTimeoutMs
            + " delivery_timeout_ms=" + deliveryTimeoutMs
            + " max_block_ms=" + maxBlockMs
            + " send_ack_timeout_ms=" + sendAckTimeoutMs);

        boolean autoCreateTopics = Boolean.parseBoolean(
            System.getenv().getOrDefault("AUTO_CREATE_TOPICS", "true")
        );

        Properties adminProps = new Properties();
        adminProps.put(AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG, "kafka:9092");

        AdminClient admin = null;
        if (!autoCreateTopics) {
            System.out.println("AUTO_CREATE_TOPICS=false → creating topics explicitly via AdminClient");
            admin = AdminClient.create(adminProps);
        }

        long sendTotalNs = 0;
        StringBuilder perMsg = new StringBuilder();
        StringBuilder batchLog = new StringBuilder();

        // 구간별 소요시간 측정을 위한 변수
        long batchStartNs = System.nanoTime();
        int batchSize = 500;
        int currentBatch = 0;

        try {
            for (int i = 1; i <= 3000; i++) {
                KafkaProducer<String, String> producer = new KafkaProducer<>(props);
                String topic = "test_topic_" + i;

                long topicCreateMs = 0;
                if (!autoCreateTopics) {
                    long topicCreateStartNs = System.nanoTime();
                    try {
                        NewTopic newTopic = new NewTopic(topic, 1, (short) 1);
                        admin.createTopics(Collections.singleton(newTopic))
                             .all()
                             .get(10, TimeUnit.SECONDS);
                    } catch (Exception e) {
                        // 이미 있으면 무시하고 진행하고 싶으면 여기서 예외 메시지 보고 continue 처리 가능
                        System.out.println("topic_create_error topic=" + topic + " error=" + e);
                        throw e;
                    }
                    long topicCreateEndNs = System.nanoTime();
                    topicCreateMs = (topicCreateEndNs - topicCreateStartNs) / 1_000_000;
                }

                long sendStartNs = System.nanoTime();
                try {
                    producer.send(new ProducerRecord<>(topic, "key", largeValue))
                            .get(sendAckTimeoutMs, TimeUnit.MILLISECONDS);
                } catch (Exception e) {
                    System.out.println("send_error idx=" + i + " topic=" + topic + " error=" + e);
                    throw e;
                }
                long sendEndNs = System.nanoTime();

                long sendMs = (sendEndNs - sendStartNs) / 1_000_000;
                sendTotalNs += (sendEndNs - sendStartNs);

                perMsg.append("send_ack_ms_").append(i).append("=")
                      .append(sendMs)
                      .append(", topic_create_ms=").append(topicCreateMs)
                      .append("\n");
                
                producer.flush();
                producer.close();

                // 500개 단위로 구간별 소요시간 기록
                if (i % batchSize == 0) {
                    long batchEndNs = System.nanoTime();
                    long batchMs = (batchEndNs - batchStartNs) / 1_000_000;
                    int rangeStart = currentBatch * batchSize + 1;
                    int rangeEnd = (currentBatch + 1) * batchSize;

                    batchLog.append("batch_").append(currentBatch + 1)
                           .append("_range=").append(rangeStart).append("~").append(rangeEnd)
                           .append(", elapsed_ms=").append(batchMs)
                           .append(", avg_ms_per_topic=").append(batchMs / batchSize)
                           .append("\n");

                    // 다음 구간을 위한 초기화
                    batchStartNs = System.nanoTime();
                    currentBatch++;
                }
            }
        } finally {
            if (admin != null) {
                admin.close();
            }
        }

        String metrics = ""
            + "timestamp=" + Instant.now() + "\n"
            + "send_ack_total_ms=" + (sendTotalNs / 1_000_000) + "\n"
            + "\n=== Batch Performance ===\n"
            + batchLog
            + "\n=== Per Message Details ===\n"
            + perMsg;

        Files.createDirectories(metricsPath.getParent());
        Files.write(metricsPath, metrics.getBytes(StandardCharsets.UTF_8));
    }
}
