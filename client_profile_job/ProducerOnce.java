import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerRecord;

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

        int idx = Integer.parseInt(
            System.getenv().getOrDefault(
                "RUN_INDEX",
                System.getenv().getOrDefault("JOB_COMPLETION_INDEX", "0")
            )
        );

        String topic = "test_topic_" + (idx + 1);

        String largeValue = "x".repeat(10_000_000); // 10MB 메시지

        long startDelayMs = Long.parseLong(
            System.getenv().getOrDefault("START_DELAY_MS", "3000")
        );
        long postSendSleepMs = Long.parseLong(
            System.getenv().getOrDefault("POST_SEND_SLEEP_MS", "1000")
        );
        int numMessages = Integer.parseInt(
            System.getenv().getOrDefault("NUM_MESSAGES", "5")
        );

        String runDir = System.getenv().getOrDefault("RUN_DIR", "/profiles/run-0");
        String runTs = System.getenv().getOrDefault("RUN_TS", "unknown");
        Path metricsPath = Path.of(runDir, "metrics" + ".txt");

        // async-profiler attach 대기
        // Thread.sleep(startDelayMs);

        System.out.println("producer_start topic=" + topic
            + " payload_bytes=" + largeValue.length()
            + " num_messages=" + numMessages
            + " send_ack_timeout_ms=" + sendAckTimeoutMs);

        long initStartNs = System.nanoTime();
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
            + "topic=" + topic + "\n"
            + "payload_bytes=" + largeValue.length() + "\n"
            + "num_messages=" + numMessages + "\n"
            + "producer_init_ms=" + ((initEndNs - initStartNs) / 1_000_000) + "\n"
            + "send_ack_total_ms=" + (sendTotalNs / 1_000_000) + "\n"
            + perMsg;

        Files.createDirectories(metricsPath.getParent());
        Files.write(metricsPath, metrics.getBytes(StandardCharsets.UTF_8));

        // profiler flush 여유
        Thread.sleep(postSendSleepMs);
    }
}
