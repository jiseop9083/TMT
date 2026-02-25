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

import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.utils.Exit;

import java.io.File;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Properties;
import java.util.Random;

/**
 * Measures Producer latency: time from send() to receiving ack.
 * Tests multiple topics (test_topic_1 ~ test_topic_N) with 1 message each.
 * Includes metadata fetch time for new topics (when auto.create.topics.enable=true).
 *
 * Usage:
 *   kafka-producer-latency.sh --bootstrap-server localhost:9092 --num-topics 3000
 */
public class ProducerLatency {

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
        // Parse arguments
        String bootstrapServer = getArg(args, "--bootstrap-server", null);
        int numTopics = Integer.parseInt(getArg(args, "--num-topics", "100"));
        String topicPrefix = getArg(args, "--topic-prefix", "test_topic_");
        int recordSize = Integer.parseInt(getArg(args, "--record-size", "10485000"));
        String acks = getArg(args, "--acks", "1");
        String outputFile = getArg(args, "--output", null);

        if (bootstrapServer == null) {
            printUsage();
            return;
        }

        // Generate output filename if not specified
        if (outputFile == null) {
            String timestamp = new SimpleDateFormat("yyyyMMdd_HHmmss").format(new Date());
            // Create output directory if it doesn't exist
            Path outputDir = Paths.get("output");
            if (!Files.exists(outputDir)) {
                Files.createDirectories(outputDir);
            }
            outputFile = outputDir.resolve("producer_latency_results_" + timestamp + ".csv").toString();
        }

        // Create producer config
        Properties props = new Properties();
        props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServer);
        props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, "org.apache.kafka.common.serialization.ByteArraySerializer");
        props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, "org.apache.kafka.common.serialization.ByteArraySerializer");
        props.put(ProducerConfig.ACKS_CONFIG, acks);
        props.put(ProducerConfig.LINGER_MS_CONFIG, "0");
        props.put(ProducerConfig.MAX_REQUEST_SIZE_CONFIG, "11534336"); // ~11MB to accommodate 10MB payloads + overhead
        // Strictly serialize all requests: one request in-flight at a time.
        // Prevents IllegalStateException("There are no in-flight requests for node N")
        // that occurs when MetadataResponse and disconnection race in the sender I/O thread.
        props.put(ProducerConfig.MAX_IN_FLIGHT_REQUESTS_PER_CONNECTION, "1");
        // Always fetch fresh metadata for each new producer instance.
        props.put(ProducerConfig.METADATA_MAX_AGE_CONFIG, "100");

        // Generate random payload
        Random random = new Random();
        byte[] payload = new byte[recordSize];
        random.nextBytes(payload);

        System.out.println("============================================");
        System.out.println("Producer Latency Multi-Topic Test");
        System.out.println("(send -> ack, includes metadata fetch)");
        System.out.println("============================================");
        System.out.println("Num Topics: " + numTopics);
        System.out.println("Topic prefix: " + topicPrefix);
        System.out.println("Record size: " + recordSize + " bytes");
        System.out.println("Bootstrap server: " + bootstrapServer);
        System.out.println("Output file: " + outputFile);
        System.out.println("============================================");

        long[] latencies = new long[numTopics];
        long totalTime = 0;

        try (PrintWriter writer = new PrintWriter(new FileWriter(outputFile))) {
            // CSV header
            writer.println("topic_num,topic_name,e2e_ms,wait_on_metadata_count");

            // Create new producer for each topic (includes full metadata fetch each time)
            for (int i = 1; i <= numTopics; i++) {
                String topicName = topicPrefix + i;

                // Retry up to 3 times with a fresh producer on failure (e.g. sender thread race)
                boolean success = false;
                int maxRetries = 3;
                for (int attempt = 1; attempt <= maxRetries && !success; attempt++) {
                    try (KafkaProducer<byte[], byte[]> producer = new KafkaProducer<>(props)) {
                        long start = System.nanoTime();
                        producer.send(new ProducerRecord<>(topicName, payload)).get();
                        long elapsed = System.nanoTime() - start;

                        double latencyMs = elapsed / 1_000_000.0;
                        latencies[i - 1] = elapsed / 1_000_000;
                        totalTime += elapsed;

                        // [TMT] read waitOnMetadata loop count from ThreadLocal
                        int waitOnMetadataCount = KafkaProducer.TMT_WAIT_ON_METADATA_COUNT.get();

                        // Write to CSV
                        writer.printf("%d,%s,%.6f,%d%n", i, topicName, latencyMs, waitOnMetadataCount);
                        writer.flush();

                        // Print progress
                        if (i % 100 == 0 || i == 1 || i == numTopics) {
                            System.out.printf("[%d/%d] %s: %.2f ms (wait_meta_count=%d)%n",
                                i, numTopics, topicName, latencyMs, waitOnMetadataCount);
                        }
                        success = true;
                    } catch (Exception e) {
                        if (attempt < maxRetries) {
                            System.err.printf("[%d/%d] %s: attempt %d failed (%s), retrying...%n",
                                i, numTopics, topicName, attempt, e.getMessage());
                            Thread.sleep(200);
                        } else {
                            System.err.printf("[%d/%d] %s: ERROR after %d attempts - %s%n",
                                i, numTopics, topicName, maxRetries, e.getMessage());
                            writer.printf("%d,%s,ERROR,ERROR%n", i, topicName);
                            writer.flush();
                        }
                    }
                }
            }
        }

        // Print summary
        printResults(numTopics, totalTime, latencies);
        System.out.println("\nResults saved to: " + outputFile);
    }

    private static void printResults(int numRecords, long totalTimeNanos, long[] latencies) {
        double avgMs = totalTimeNanos / 1_000_000.0 / numRecords;

        // Sort for percentiles
        java.util.Arrays.sort(latencies);
        long p50 = latencies[(int) (latencies.length * 0.5)];
        long p99 = latencies[(int) (latencies.length * 0.99)];
        long p999 = latencies[Math.min((int) (latencies.length * 0.999), latencies.length - 1)];
        long min = latencies[0];
        long max = latencies[latencies.length - 1];

        System.out.println();
        System.out.println("============================================");
        System.out.println("Summary");
        System.out.println("============================================");
        System.out.printf("Total topics: %d%n", numRecords);
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
        System.out.println("Usage: kafka-producer-latency.sh [options]");
        System.out.println();
        System.out.println("Required:");
        System.out.println("  --bootstrap-server <server>  Kafka broker address");
        System.out.println();
        System.out.println("Optional:");
        System.out.println("  --num-topics <n>             Number of topics to test (default: 3000)");
        System.out.println("  --topic-prefix <prefix>      Topic name prefix (default: test_topic_)");
        System.out.println("  --record-size <bytes>        Record size in bytes (default: 512)");
        System.out.println("  --acks <acks>                Producer acks setting (default: 1)");
        System.out.println("  --output <file>              Output CSV file (default: auto-generated)");
        System.out.println();
        System.out.println("Example:");
        System.out.println("  kafka-producer-latency.sh --bootstrap-server localhost:9092 --num-topics 3000");
        System.out.println();
        System.out.println("Output CSV format:");
        System.out.println("  topic_num,topic_name,e2e_ms,wait_on_metadata_count");
    }
}
