import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;

import java.io.BufferedWriter;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;
import java.util.Properties;
import java.util.Random;

public class TopicProduceE2E {
    public static void main(String[] args) throws Exception {
        Map<String, String> parsed = parseArgs(args);

        String bootstrap = required(parsed, "--bootstrap-server");
        String output = required(parsed, "--output");
        int numTopics = Integer.parseInt(parsed.getOrDefault("--num-topics", "1500"));
        String topicPrefix = parsed.getOrDefault("--topic-prefix", "test_topic_");
        int recordSize = Integer.parseInt(parsed.getOrDefault("--record-size", "1"));
        String acks = parsed.getOrDefault("--acks", "1");
        String stopFlagPath = parsed.get("--stop-flag-file");

        // Kafka retry.backoff.ms is LONG ms. 0.5ms input is rounded to 1ms.
        double retryBackoffInput = Double.parseDouble(parsed.getOrDefault("--retry-backoff-ms", "1"));
        long retryBackoffMs = Math.max(0L, Math.round(retryBackoffInput));

        byte[] payload = new byte[recordSize];
        new Random().nextBytes(payload);

        try (PrintWriter writer = new PrintWriter(new BufferedWriter(new FileWriter(output)))) {
            writer.println("topic_num,topic_name,latency_ms");
            writer.flush();

            for (int i = 1; i <= numTopics; i++) {
                if (stopFlagPath != null && Files.exists(Path.of(stopFlagPath))) {
                    System.out.printf("Stop flag detected. Stopping early at topic %d%n", i);
                    break;
                }

                String topicName = topicPrefix + i;
                try (KafkaProducer<byte[], byte[]> producer = new KafkaProducer<>(producerProps(bootstrap, acks, retryBackoffMs))) {
                    long startNs = System.nanoTime();
                    producer.send(new ProducerRecord<>(topicName, payload)).get();
                    long elapsedNs = System.nanoTime() - startNs;
                    double latencyMs = elapsedNs / 1_000_000.0;

                    writer.printf("%d,%s,%.4f%n", i, topicName, latencyMs);
                    writer.flush();

                    if (i % 100 == 0 || i == 1 || i == numTopics) {
                        System.out.printf("[%d/%d] %s: %.2f ms%n", i, numTopics, topicName, latencyMs);
                    }
                } catch (Exception e) {
                    writer.printf("%d,%s,ERROR%n", i, topicName);
                    writer.flush();
                    System.err.printf("[%d/%d] %s ERROR: %s%n", i, numTopics, topicName, e.getMessage());
                }
            }
        }
    }

    private static Properties producerProps(String bootstrap, String acks, long retryBackoffMs) {
        Properties props = new Properties();
        props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrap);
        props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, "org.apache.kafka.common.serialization.ByteArraySerializer");
        props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, "org.apache.kafka.common.serialization.ByteArraySerializer");
        props.put(ProducerConfig.ACKS_CONFIG, acks);
        props.put(ProducerConfig.LINGER_MS_CONFIG, "0");
        props.put(ProducerConfig.BATCH_SIZE_CONFIG, "1");
        props.put(ProducerConfig.RETRY_BACKOFF_MS_CONFIG, String.valueOf(retryBackoffMs));
        props.put(ProducerConfig.RETRY_BACKOFF_MAX_MS_CONFIG, String.valueOf(retryBackoffMs));
        props.put(ProducerConfig.REQUEST_TIMEOUT_MS_CONFIG, "120000");
        props.put(ProducerConfig.MAX_BLOCK_MS_CONFIG, "120000");
        props.put(ProducerConfig.MAX_REQUEST_SIZE_CONFIG, "11534336");
        return props;
    }

    private static String required(Map<String, String> parsed, String key) {
        if (!parsed.containsKey(key)) {
            throw new IllegalArgumentException("Missing required arg: " + key);
        }
        return parsed.get(key);
    }

    private static Map<String, String> parseArgs(String[] args) {
        Map<String, String> out = new HashMap<>();
        for (int i = 0; i < args.length; i++) {
            String key = args[i];
            if (!key.startsWith("--")) {
                continue;
            }
            if (i + 1 < args.length && !args[i + 1].startsWith("--")) {
                out.put(key, args[++i]);
            } else {
                out.put(key, "true");
            }
        }
        return out;
    }
}
