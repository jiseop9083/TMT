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
import org.apache.kafka.common.errors.TopicExistsException;

public class ProduceMessages {
    public static void main(String[] args) throws Exception {
        Properties props = new Properties();
        props.put("bootstrap.servers", "my-cluster-kafka-bootstrap:9092");
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
        boolean warmupOnly = Boolean.parseBoolean(
            System.getenv().getOrDefault("WARMUP_ONLY", "false")
        );
        boolean writeMetrics = Boolean.parseBoolean(
            System.getenv().getOrDefault("WRITE_METRICS", "true")
        );
        int warmupSends = Integer.parseInt(
            System.getenv().getOrDefault("FIRST_TOPIC_WARMUP_SENDS", "0")
        );

        Properties adminProps = new Properties();
        adminProps.put(AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG, "my-cluster-kafka-bootstrap:9092");

        AdminClient admin = null;
        if (!autoCreateTopics) {
            System.out.println("AUTO_CREATE_TOPICS=false → creating topics explicitly via AdminClient");
            admin = AdminClient.create(adminProps);
        }

        if (warmupOnly) {
            if (warmupSends > 0) {
                String warmupTopic = "test_topic_1";
                System.out.println("warmup_start topic=" + warmupTopic + " sends=" + warmupSends);
                if (!autoCreateTopics) {
                    try {
                        NewTopic newTopic = new NewTopic(warmupTopic, 1, (short) 1);
                        admin.createTopics(Collections.singleton(newTopic))
                             .all()
                             .get(10, TimeUnit.SECONDS);
                    } catch (Exception e) {
                        if (isTopicExists(e)) {
                            System.out.println("warmup_topic_exists topic=" + warmupTopic);
                        } else {
                            System.out.println("warmup_topic_create_error topic=" + warmupTopic + " error=" + e);
                            throw e;
                        }
                    }
                }

                KafkaProducer<String, String> producer = new KafkaProducer<>(props);
                try {
                    for (int i = 1; i <= warmupSends; i++) {
                        producer.send(new ProducerRecord<>(warmupTopic, "key", largeValue))
                                .get(sendAckTimeoutMs, TimeUnit.MILLISECONDS);
                    }
                } finally {
                    producer.flush();
                    producer.close();
                }
                System.out.println("warmup_done topic=" + warmupTopic + " sends=" + warmupSends);
            } else {
                System.out.println("warmup_skipped sends=0");
            }
            if (admin != null) {
                admin.close();
            }
            return;
        }

        long sendTotalNs = 0;
        StringBuilder perMsg = new StringBuilder();

        try {
            for (int i = 1; i <= 1000; i++) {
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
                        if (isTopicExists(e)) {
                            System.out.println("topic_exists topic=" + topic);
                        } else {
                            System.out.println("topic_create_error topic=" + topic + " error=" + e);
                            throw e;
                        }
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
            }
        } finally {
            if (admin != null) {
                admin.close();
            }
        }

        String metrics = ""
            + "timestamp=" + Instant.now() + "\n"
            + "send_ack_total_ms=" + (sendTotalNs / 1_000_000) + "\n"
            + perMsg;

        if (writeMetrics) {
            Files.createDirectories(metricsPath.getParent());
            Files.write(metricsPath, metrics.getBytes(StandardCharsets.UTF_8));
        }
    }

    private static boolean isTopicExists(Throwable e) {
        Throwable cause = e;
        while (cause != null) {
            if (cause instanceof TopicExistsException) {
                return true;
            }
            cause = cause.getCause();
        }
        return false;
    }
}
