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

        int idx = Integer.parseInt(
            System.getenv().getOrDefault("JOB_COMPLETION_INDEX", "0")
        );

        String topic = "test_topic_" + (idx + 1);

        // async-profiler attach 대기
        Thread.sleep(10000); // 10초

        KafkaProducer<String, String> producer = new KafkaProducer<>(props);
        producer.send(new ProducerRecord<>(topic, "key", "value")).get();
        producer.flush();
        producer.close();

        long end = System.nanoTime();

        // profiler flush 여유
        Thread.sleep(60_000); // 60초

    }
}
