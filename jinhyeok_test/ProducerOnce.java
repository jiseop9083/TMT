import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerRecord;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Properties;

public class ProducerOnce {
    public static void main(String[] args) throws Exception {
        Properties props = new Properties();
        props.put("bootstrap.servers", "my-cluster-kafka-bootstrap:9092");
        props.put("key.serializer", "org.apache.kafka.common.serialization.StringSerializer");
        props.put("value.serializer", "org.apache.kafka.common.serialization.StringSerializer");
        props.put("acks", "all");

        long start = System.nanoTime();

        // async-profiler attach 대기
        Thread.sleep(10000); // 10초

        KafkaProducer<String, String> producer = new KafkaProducer<>(props);
        producer.send(new ProducerRecord<>("test-topic", "key", "value")).get();
        producer.flush();
        producer.close();

        long end = System.nanoTime();

        Files.writeString(
            Path.of("/profiles/metrics.txt"),
            "produce_latency_ns=" + (end - start)
        );

        // profiler flush 여유
        Thread.sleep(1000);
        Thread.sleep(60_000); // 60초

    }
}
