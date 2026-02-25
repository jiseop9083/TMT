/*
 * Licensed to the Apache Software Foundation (ASF) under one or more
 * contributor license agreements. See the NOTICE file distributed with
 * this work for additional information regarding copyright ownership.
 * The ASF licenses this file to You under the Apache License, Version 2.0
 * (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package org.apache.kafka.tools;

import org.apache.kafka.clients.admin.AdminClient;
import org.apache.kafka.clients.admin.AdminClientConfig;
import org.apache.kafka.clients.admin.NewTopic;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.utils.Exit;

import java.io.FileWriter;
import java.io.PrintWriter;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Date;
import java.util.List;
import java.util.Properties;
import java.util.Random;
import java.util.concurrent.TimeUnit;

/**
 * Measures how the number of existing topics affects Produce request latency.
 *
 * For each i (1..N):
 *   1) AdminClient creates test_topic_i (now i topics exist)
 *   2) 15 Produce requests to test_topic_i, each with a NEW KafkaProducer
 *      (so metadata fetch is included every time)
 *
 * This reveals the correlation between topic count and produce handling speed.
 *
 * Usage:
 *   kafka-producer-latency-multi.sh --bootstrap-server localhost:9092 --num-topics 3000 --num-sends 15
 */
public class ProducerLatencyMultiSend {

    public static void main(String[] args) {
        Exit.exit(mainNoExit(args));
    }

    static int mainNoExit(String[] args) {
        try {
            execute(args);
            return 0;
        } catch (Exception e) {
            System.err.println("Error: " + e.getMessage());
            e.printStackTrace();
            return 1;
        }
    }

    static void execute(String[] args) throws Exception {
        String bootstrapServer = getArg(args, "--bootstrap-server", null);
        int numTopics = Integer.parseInt(getArg(args, "--num-topics", "3000"));
        int numSends = Integer.parseInt(getArg(args, "--num-sends", "15"));
        String topicPrefix = getArg(args, "--topic-prefix", "test_topic_");
        int recordSize = Integer.parseInt(getArg(args, "--record-size", "1048576"));
        String acks = getArg(args, "--acks", "1");
        String outputFile = getArg(args, "--output", null);
        int partitions = Integer.parseInt(getArg(args, "--partitions", "1"));
        short replicationFactor = Short.parseShort(getArg(args, "--replication-factor", "1"));

        if (bootstrapServer == null) {
            printUsage();
            return;
        }

        if (outputFile == null) {
            String timestamp = new SimpleDateFormat("yyyyMMdd_HHmmss").format(new Date());
            Path outputDir = Paths.get("output");
            if (!Files.exists(outputDir)) {
                Files.createDirectories(outputDir);
            }
            outputFile = outputDir.resolve("producer_latency_multi_" + timestamp + ".csv").toString();
        }

        // AdminClient config
        Properties adminProps = new Properties();
        adminProps.put(AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServer);

        // Producer config
        Properties producerProps = new Properties();
        producerProps.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServer);
        producerProps.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, "org.apache.kafka.common.serialization.ByteArraySerializer");
        producerProps.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, "org.apache.kafka.common.serialization.ByteArraySerializer");
        producerProps.put(ProducerConfig.ACKS_CONFIG, acks);
        producerProps.put(ProducerConfig.LINGER_MS_CONFIG, "0");
        producerProps.put(ProducerConfig.BATCH_SIZE_CONFIG, "1");
        producerProps.put(ProducerConfig.MAX_REQUEST_SIZE_CONFIG, "11534336");

        Random random = new Random();
        byte[] payload = new byte[recordSize];
        random.nextBytes(payload);

        int totalRequests = numTopics * numSends;

        System.out.println("============================================");
        System.out.println("Producer Latency vs Topic Count Test");
        System.out.println("(AdminClient creates topic, then produce)");
        System.out.println("============================================");
        System.out.println("Num Topics: " + numTopics);
        System.out.println("Sends per topic: " + numSends);
        System.out.println("Total requests: " + totalRequests);
        System.out.println("Topic prefix: " + topicPrefix);
        System.out.println("Partitions per topic: " + partitions);
        System.out.println("Replication factor: " + replicationFactor);
        System.out.println("Record size: " + recordSize + " bytes");
        System.out.println("Bootstrap server: " + bootstrapServer);
        System.out.println("Output file: " + outputFile);
        System.out.println("============================================");

        List<Long> allLatencies = new ArrayList<>();
        long totalTime = 0;
        int completedRequests = 0;

        try (AdminClient adminClient = AdminClient.create(adminProps);
             PrintWriter writer = new PrintWriter(new FileWriter(outputFile))) {

            writer.println("topic_num,topic_name,latency_ms");

            for (int i = 1; i <= numTopics; i++) {
                String topicName = topicPrefix + i;

                // Step 1: Create topic via AdminClient and wait for completion
                NewTopic newTopic = new NewTopic(topicName, partitions, replicationFactor);
                try {
                    adminClient.createTopics(Collections.singleton(newTopic)).all().get();
                } catch (Exception e) {
                    // Topic may already exist, continue
                    System.err.printf("[Topic %d/%d] %s creation skipped: %s%n",
                        i, numTopics, topicName, e.getCause() != null ? e.getCause().getMessage() : e.getMessage());
                }

                // Wait for broker to set up log directories and elect leader
                Thread.sleep(300);

                // Step 2: Send numSends produce requests, each with a new producer
                for (int j = 1; j <= numSends; j++) {
                    try (KafkaProducer<byte[], byte[]> producer = new KafkaProducer<>(producerProps)) {
                        long start = System.nanoTime();
                        producer.send(new ProducerRecord<>(topicName, payload)).get();
                        long elapsed = System.nanoTime() - start;

                        double latencyMs = elapsed / 1_000_000.0;
                        allLatencies.add(elapsed / 1_000_000);
                        totalTime += elapsed;
                        completedRequests++;

                        writer.printf("%d,%s,%.4f%n", i, topicName, latencyMs);
                        writer.flush();

                        if (j == 1 && (i % 100 == 0 || i == 1 || i == numTopics)) {
                            System.out.printf("[Topic %d/%d, Send %d/%d] %s: %.2f ms%n",
                                i, numTopics, j, numSends, topicName, latencyMs);
                        }
                    } catch (Exception e) {
                        System.err.printf("[Topic %d/%d, Send %d/%d] %s: ERROR - %s%n",
                            i, numTopics, j, numSends, topicName, e.getMessage());
                        writer.printf("%d,%s,ERROR%n", i, topicName);
                        writer.flush();
                    }
                }
            }
        }

        printResults(completedRequests, totalTime, allLatencies);
        System.out.println("\nResults saved to: " + outputFile);
    }

    private static void printResults(int numRecords, long totalTimeNanos, List<Long> latencyList) {
        if (numRecords == 0) {
            System.out.println("No successful records.");
            return;
        }

        double avgMs = totalTimeNanos / 1_000_000.0 / numRecords;
        long[] latencies = latencyList.stream().mapToLong(Long::longValue).sorted().toArray();
        long p50 = latencies[(int) (latencies.length * 0.5)];
        long p99 = latencies[(int) (latencies.length * 0.99)];
        long p999 = latencies[Math.min((int) (latencies.length * 0.999), latencies.length - 1)];
        long min = latencies[0];
        long max = latencies[latencies.length - 1];

        System.out.println();
        System.out.println("============================================");
        System.out.println("Summary");
        System.out.println("============================================");
        System.out.printf("Total requests: %d%n", numRecords);
        System.out.printf("Avg latency: %.4f ms%n", avgMs);
        System.out.printf("Percentiles: 50th = %d ms, 99th = %d ms, 99.9th = %d ms%n", p50, p99, p999);
        System.out.printf("Min: %d ms, Max: %d ms%n", min, max);
    }

    private static String getArg(String[] args, String name, String defaultValue) {
        for (int i = 0; i < args.length - 1; i++) {
            if (args[i].equals(name)) {
                return args[i + 1];
            }
        }
        return defaultValue;
    }

    private static void printUsage() {
        System.out.println("Usage: kafka-producer-latency-multi.sh [options]");
        System.out.println();
        System.out.println("Required:");
        System.out.println("  --bootstrap-server <server>  Kafka broker address");
        System.out.println();
        System.out.println("Optional:");
        System.out.println("  --num-topics <n>             Number of topics (default: 3000)");
        System.out.println("  --num-sends <n>              Sends per topic (default: 15)");
        System.out.println("  --topic-prefix <prefix>      Topic name prefix (default: test_topic_)");
        System.out.println("  --record-size <bytes>        Record size in bytes (default: 1048576 = 1MB)");
        System.out.println("  --partitions <n>             Partitions per topic (default: 1)");
        System.out.println("  --replication-factor <n>     Replication factor (default: 1)");
        System.out.println("  --acks <acks>                Producer acks setting (default: 1)");
        System.out.println("  --output <file>              Output CSV file (default: auto-generated)");
        System.out.println();
        System.out.println("Example:");
        System.out.println("  kafka-producer-latency-multi.sh --bootstrap-server localhost:9092 --num-topics 3000 --num-sends 15");
        System.out.println();
        System.out.println("Output CSV format:");
        System.out.println("  topic_num,topic_name,latency_ms");
    }
}
