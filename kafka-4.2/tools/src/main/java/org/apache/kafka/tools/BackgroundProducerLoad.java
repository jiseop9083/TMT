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

import java.util.Collections;
import java.util.Properties;
import java.util.Random;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Background producer load generator.
 *
 * Spawns N producer threads that each send a message every intervalMs to a
 * specified topic. Runs until the process is terminated (SIGTERM / SIGINT).
 *
 * Usage:
 *   kafka-background-producer-load.sh \
 *       --bootstrap-server localhost:9092 \
 *       --topic load_topic \
 *       --num-producers 5 \
 *       --interval-ms 300 \
 *       --record-size 1024
 */
public class BackgroundProducerLoad {

    private static final AtomicBoolean RUNNING = new AtomicBoolean(true);

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
        String topic = getArg(args, "--topic", "background_load_topic");
        int numProducers = Integer.parseInt(getArg(args, "--num-producers", "100"));
        long intervalMs = Long.parseLong(getArg(args, "--interval-ms", "300"));
        int recordSize = Integer.parseInt(getArg(args, "--record-size", "1024"));
        String acks = getArg(args, "--acks", "1");

        if (bootstrapServer == null) {
            printUsage();
            return;
        }

        // Create the load topic if it doesn't exist
        Properties adminProps = new Properties();
        adminProps.put(AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServer);
        try (AdminClient adminClient = AdminClient.create(adminProps)) {
            NewTopic newTopic = new NewTopic(topic, 1, (short) 1);
            try {
                adminClient.createTopics(Collections.singleton(newTopic)).all().get();
                System.out.println("Created load topic: " + topic);
                Thread.sleep(1000);
            } catch (Exception e) {
                System.out.println("Load topic already exists or creation skipped: " + topic);
            }
        }

        System.out.println("============================================");
        System.out.println("Background Producer Load Generator");
        System.out.println("============================================");
        System.out.printf("Topic:          %s%n", topic);
        System.out.printf("Num producers:  %d%n", numProducers);
        System.out.printf("Interval:       %d ms%n", intervalMs);
        System.out.printf("Record size:    %d bytes%n", recordSize);
        System.out.printf("Bootstrap:      %s%n", bootstrapServer);
        System.out.println("============================================");
        System.out.println("Sending background load... (kill process to stop)");

        // Register shutdown hook
        AtomicLong totalSent = new AtomicLong(0);
        CountDownLatch shutdownLatch = new CountDownLatch(numProducers);

        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            System.out.println("\nShutting down background producers...");
            RUNNING.set(false);
            try {
                shutdownLatch.await();
            } catch (InterruptedException ignored) {
            }
            System.out.printf("Total messages sent: %d%n", totalSent.get());
        }));

        // Spawn producer threads
        Random random = new Random();
        byte[] payload = new byte[recordSize];
        random.nextBytes(payload);

        Thread[] threads = new Thread[numProducers];
        for (int i = 0; i < numProducers; i++) {
            final int producerId = i;
            threads[i] = new Thread(() -> {
                Properties producerProps = new Properties();
                producerProps.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServer);
                producerProps.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG,
                    "org.apache.kafka.common.serialization.ByteArraySerializer");
                producerProps.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG,
                    "org.apache.kafka.common.serialization.ByteArraySerializer");
                producerProps.put(ProducerConfig.ACKS_CONFIG, acks);
                producerProps.put(ProducerConfig.LINGER_MS_CONFIG, "0");
                producerProps.put(ProducerConfig.BATCH_SIZE_CONFIG, "1");

                try (KafkaProducer<byte[], byte[]> producer = new KafkaProducer<>(producerProps)) {
                    long count = 0;
                    while (RUNNING.get()) {
                        try {
                            producer.send(new ProducerRecord<>(topic, payload)).get();
                            count++;
                            totalSent.incrementAndGet();

                            if (count % 100 == 0) {
                                System.out.printf("[Producer-%d] Sent %d messages%n", producerId, count);
                            }
                        } catch (Exception e) {
                            System.err.printf("[Producer-%d] Send error: %s%n", producerId, e.getMessage());
                        }

                        try {
                            Thread.sleep(intervalMs);
                        } catch (InterruptedException e) {
                            break;
                        }
                    }
                    System.out.printf("[Producer-%d] Stopped after %d messages%n", producerId, count);
                }
                shutdownLatch.countDown();
            }, "bg-producer-" + i);
            threads[i].setDaemon(true);
            threads[i].start();
        }

        // Wait for shutdown signal
        try {
            while (RUNNING.get()) {
                Thread.sleep(1000);
            }
        } catch (InterruptedException ignored) {
        }
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
        System.out.println("Usage: kafka-background-producer-load.sh [options]");
        System.out.println();
        System.out.println("Required:");
        System.out.println("  --bootstrap-server <server>  Kafka broker address");
        System.out.println();
        System.out.println("Optional:");
        System.out.println("  --topic <name>               Load topic name (default: background_load_topic)");
        System.out.println("  --num-producers <n>           Number of producer threads (default: 5)");
        System.out.println("  --interval-ms <ms>            Send interval per producer (default: 300)");
        System.out.println("  --record-size <bytes>         Record size in bytes (default: 1024)");
        System.out.println("  --acks <acks>                 Producer acks (default: 1)");
    }
}
