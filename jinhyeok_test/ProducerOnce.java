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
        props.put("max.request.size", 15_000_000);   

        int idx = Integer.parseInt(
            System.getenv().getOrDefault("JOB_COMPLETION_INDEX", "0")
        );

        String topic = "test_topic_" + (idx + 1);

        String largeValue = "x".repeat(10_000_000); // 10MB 메시지

        // async-profiler attach 대기
        Thread.sleep(10000); // 10초

        KafkaProducer<String, String> producer = new KafkaProducer<>(props);
        producer.send(new ProducerRecord<>(topic, "key", largeValue)).get();
        producer.flush();
        producer.close();

        long end = System.nanoTime();

        // profiler flush 여유
        Thread.sleep(60_000); // 60초

    }
}
