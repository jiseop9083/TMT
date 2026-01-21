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

public class ProducerOnce {
    public static void main(String[] args) throws Exception {
        Properties props = new Properties();
        props.put("bootstrap.servers", "my-cluster-kafka-bootstrap:9092");
        props.put("key.serializer", "org.apache.kafka.common.serialization.StringSerializer");
        props.put("value.serializer", "org.apache.kafka.common.serialization.StringSerializer");
        String acks = System.getenv().getOrDefault("ACKS", "1");
        props.put("acks", acks);
        props.put("max.request.size", 15_000_000);   

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

        // JOB_INDEX_OFFSET + JOB_COMPLETION_INDEX로 전역 인덱스 계산
        String offsetStr = System.getenv("JOB_INDEX_OFFSET");
        int offset = (offsetStr == null || offsetStr.isEmpty()) ? 0 : Integer.parseInt(offsetStr);
        
        String localIdxStr = System.getenv("JOB_COMPLETION_INDEX");
        int localIdx = (localIdxStr == null || localIdxStr.isEmpty()) ? 0 : Integer.parseInt(localIdxStr);
        
        // 전역 인덱스 (1-based): offset은 0-based, localIdx도 0-based
        int globalIdx = offset + localIdx + 1;
        
        String topic = "test_topic_" + globalIdx;

        String largeValue = "x".repeat(10000000) + "\n"; // 10MB 메시지

        long startDelayMs = Long.parseLong(
            System.getenv().getOrDefault("START_DELAY_MS", "3000")
        );
        long postSendSleepMs = Long.parseLong(
            System.getenv().getOrDefault("POST_SEND_SLEEP_MS", "1000")
        );
        int numMessages = Integer.parseInt(
            System.getenv().getOrDefault("NUM_MESSAGES", "5")
        );
        
        String runDir = "/profiles/run-" + globalIdx;
        String runTs = System.getenv().getOrDefault("RUN_TS", "unknown");
        Path metricsPath = Path.of(runDir, "metrics.txt");

        // async-profiler attach 대기
        // Thread.sleep(startDelayMs);

        System.out.println("producer_start topic=" + topic
            + " global_index=" + globalIdx
            + " payload_bytes=" + largeValue.length()
            + " num_messages=" + numMessages
            + " send_ack_timeout_ms=" + sendAckTimeoutMs);

        long initStartNs = System.nanoTime();

        boolean autoCreateTopics =
            Boolean.parseBoolean(System.getenv().getOrDefault("AUTO_CREATE_TOPICS", "true"));

        if (!autoCreateTopics) {
            System.out.println("auto.create.topics.enable=false → creating topic explicitly");

            Properties adminProps = new Properties();
            adminProps.put(AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG,
                        "my-cluster-kafka-bootstrap:9092");

            try (AdminClient admin = AdminClient.create(adminProps)) {
                NewTopic newTopic = new NewTopic(topic, 1, (short) 1);
                admin.createTopics(Collections.singleton(newTopic))
                    .all()
                    .get(10, TimeUnit.SECONDS);
            }
        }

        
        KafkaProducer<String, String> producer = new KafkaProducer<>(props);
        long initEndNs = System.nanoTime();

        System.out.println("producer_init_ms=" + ((initEndNs - initStartNs) / 1_000_000));

        long sendTotalNs = 0;
        StringBuilder perMsg = new StringBuilder();
        for (int i = 0; i < numMessages; i++) {
            long sendStartNs = System.nanoTime();
            try {
                producer.send(new ProducerRecord<>(topic, "key", largeValue))
                    .get(sendAckTimeoutMs, TimeUnit.MILLISECONDS);
            } catch (Exception e) {
                System.out.println("send_error idx=" + (i + 1) + " error=" + e);
                throw e;
            }
            long sendEndNs = System.nanoTime();
            long sendMs = (sendEndNs - sendStartNs) / 1_000_000;
            sendTotalNs += (sendEndNs - sendStartNs);
            perMsg.append("send_ack_ms_").append(i + 1).append("=")
                .append(sendMs).append("\n");
        }
        producer.flush();
        producer.close();

        String metrics = ""
            + "timestamp=" + Instant.now() + "\n"
            + "global_index=" + globalIdx + "\n"
            + "topic=" + topic + "\n"
            + "payload_bytes=" + largeValue.length() + "\n"
            + "num_messages=" + numMessages + "\n"
            + "producer_init_ms=" + ((initEndNs - initStartNs) / 1_000_000) + "\n"
            + "send_ack_total_ms=" + (sendTotalNs / 1_000_000) + "\n"
            + perMsg;

        Files.createDirectories(metricsPath.getParent());
        Files.write(metricsPath, metrics.getBytes(StandardCharsets.UTF_8));

        // profiler flush 여유
        // Thread.sleep(postSendSleepMs);
    }
}