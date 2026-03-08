import org.apache.kafka.clients.admin.Admin;
import org.apache.kafka.clients.admin.TopicDescription;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.Producer;
import org.apache.kafka.clients.producer.ProducerRecord;

import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import java.util.Properties;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class TopicChurnRunner {
    private static final DateTimeFormatter TS_FMT = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS");
    private static final Pattern BROKER_METADATA_UPDATE_PATTERN =
        Pattern.compile("BROKER_METADATA_UPDATE\\s+elapsed_ms=([0-9]+(?:\\.[0-9]+)?)\\s+topics=([^\\s]+)");

    private static String nowIsoMs() {
        return LocalDateTime.now().format(TS_FMT);
    }

    private static long nowEpochMs() {
        return System.currentTimeMillis();
    }

    private static String phaseForCreatedCount(int createdCount, int deleteStartCount) {
        return createdCount < deleteStartCount ? "create_only" : "create_delete";
    }

    private static String esc(String s) {
        return s == null ? "" : s.replace(',', ';').replace('\n', ' ').replace('\r', ' ');
    }

    private static long elapsedUs(long startNs) {
        return TimeUnit.NANOSECONDS.toMicros(System.nanoTime() - startNs);
    }

    private static boolean metadataReady(TopicDescription desc) {
        if (desc == null || desc.partitions() == null || desc.partitions().isEmpty()) {
            return false;
        }
        for (var p : desc.partitions()) {
            if (p.leader() == null || p.leader().id() < 0) {
                return false;
            }
        }
        return true;
    }

    private static MetadataWaitResult waitUntilMetadataReady(Admin admin, String topicName,
                                                             long timeoutMs, long pollMs) {
        long startNs = System.nanoTime();
        long deadlineMs = nowEpochMs() + timeoutMs;
        while (nowEpochMs() <= deadlineMs) {
            try {
                Map<String, TopicDescription> result =
                    admin.describeTopics(Collections.singletonList(topicName)).allTopicNames().get();
                TopicDescription desc = result.get(topicName);
                if (metadataReady(desc)) {
                    return new MetadataWaitResult(elapsedUs(startNs), "OK", "");
                }
            } catch (Exception e) {
                // Retry until timeout.
            }

            try {
                Thread.sleep(pollMs);
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
                return new MetadataWaitResult(elapsedUs(startNs), "ERROR", "metadata-wait-interrupted");
            }
        }
        return new MetadataWaitResult(elapsedUs(startNs), "ERROR", "metadata-wait-timeout");
    }

    private static final class MetadataWaitResult {
        final long durationUs;
        final String status;
        final String error;

        MetadataWaitResult(long durationUs, String status, String error) {
            this.durationUs = durationUs;
            this.status = status;
            this.error = error;
        }
    }

    private static final class BrokerMetadataLogTracker {
        private final Path brokerLogPath;
        private final Map<String, Double> latestByTopic = new HashMap<>();
        private long position = 0L;

        BrokerMetadataLogTracker(Path brokerLogPath) {
            this.brokerLogPath = brokerLogPath;
        }

        synchronized double latestForTopic(String topic) {
            refresh();
            return latestByTopic.getOrDefault(topic, Double.NaN);
        }

        private void refresh() {
            if (!Files.exists(brokerLogPath)) {
                return;
            }
            try (RandomAccessFile raf = new RandomAccessFile(brokerLogPath.toFile(), "r")) {
                long length = raf.length();
                if (position > length) {
                    position = 0L;
                }
                raf.seek(position);
                String line;
                while ((line = raf.readLine()) != null) {
                    Matcher matcher = BROKER_METADATA_UPDATE_PATTERN.matcher(line);
                    if (!matcher.find()) {
                        continue;
                    }
                    double elapsedMs;
                    try {
                        elapsedMs = Double.parseDouble(matcher.group(1));
                    } catch (NumberFormatException e) {
                        continue;
                    }
                    String topics = matcher.group(2);
                    for (String topic : topics.split("\\|")) {
                        if (!topic.isBlank()) {
                            latestByTopic.put(topic, elapsedMs);
                        }
                    }
                }
                position = raf.getFilePointer();
            } catch (IOException ignored) {
                // Best-effort parsing only.
            }
        }
    }

    private static void appendLine(Path path, String line) throws IOException {
        Files.writeString(path, line + System.lineSeparator(), StandardCharsets.UTF_8,
            StandardOpenOption.CREATE, StandardOpenOption.APPEND);
    }

    private static void writePhase(Path phaseFile, String phase) throws IOException {
        Files.writeString(phaseFile, phase, StandardCharsets.UTF_8,
            StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING);
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 13) {
            System.err.println("Usage: TopicChurnRunner <bootstrap> <createOnlyCount> <phase2DurationSec> <intervalMs> <topicPrefix> <partitions> <replicationFactor> <topicOpsCsv> <eventsCsv> <phaseFile> <topicCreateRequestsCsv> <e2eCsv> <brokerLogPath>");
            System.exit(1);
        }

        final String bootstrap = args[0];
        final int createOnlyCount = Integer.parseInt(args[1]);
        final int phase2DurationSec = Integer.parseInt(args[2]);
        final int intervalMs = Integer.parseInt(args[3]);
        final String topicPrefix = args[4];
        final int partitions = Integer.parseInt(args[5]);
        final short replicationFactor = Short.parseShort(args[6]);
        final Path topicOpsCsv = Path.of(args[7]);
        final Path eventsCsv = Path.of(args[8]);
        final Path phaseFile = Path.of(args[9]);
        final Path topicCreateRequestsCsv = Path.of(args[10]);
        final Path e2eCsv = Path.of(args[11]);
        final Path brokerLogPath = Path.of(args[12]);
        final BrokerMetadataLogTracker brokerMetadataLogTracker = new BrokerMetadataLogTracker(brokerLogPath);

        Properties props = new Properties();
        props.put("bootstrap.servers", bootstrap);
        props.put("request.timeout.ms", "30000");
        props.put("default.api.timeout.ms", "30000");
        Properties producerProps = new Properties();
        producerProps.put("bootstrap.servers", bootstrap);
        producerProps.put("acks", "1");
        producerProps.put("linger.ms", "0");
        producerProps.put("request.timeout.ms", "30000");
        producerProps.put("delivery.timeout.ms", "120000");
        producerProps.put("max.block.ms", "30000");
        producerProps.put("key.serializer", "org.apache.kafka.common.serialization.ByteArraySerializer");
        producerProps.put("value.serializer", "org.apache.kafka.common.serialization.ByteArraySerializer");

        int createdCount = 0;
        int deletedCount = 0;
        int deleteIdx = 1;
        boolean startedDelete = false;

        long phase2EndMs = -1L;

        try (Admin admin = Admin.create(props);
             Producer<byte[], byte[]> producer = new KafkaProducer<>(producerProps)) {
            while (true) {
                long now = nowEpochMs();
                if (phase2EndMs > 0) {
                    if (now >= phase2EndMs) break;
                }

                createdCount += 1;
                String localPhase = phaseForCreatedCount(createdCount, createOnlyCount);
                writePhase(phaseFile, localPhase);
                String topicName = topicPrefix + createdCount;

                long requestStartNs = System.nanoTime();
                long produceStartNs = System.nanoTime();
                String cStatus = "ok";
                String cErr = "";
                try {
                    producer.send(new ProducerRecord<>(topicName, null, new byte[] {0x00})).get();
                } catch (Exception e) {
                    cStatus = "error";
                    cErr = "produce-failed:" + esc(e.getMessage());
                }
                long produceDurationUs = elapsedUs(produceStartNs);
                long onMetadataDurationUs = 0L;
                String reqStatus = "OK";
                String reqErr = "";
                if ("ok".equals(cStatus)) {
                    MetadataWaitResult waitResult = waitUntilMetadataReady(admin, topicName, 30_000L, 20L);
                    onMetadataDurationUs = waitResult.durationUs;
                    reqStatus = waitResult.status;
                    reqErr = waitResult.error;
                } else {
                    reqStatus = "ERROR";
                    reqErr = cErr;
                }
                long e2eLatencyUs = produceDurationUs + onMetadataDurationUs;
                long requestLatencyUs = elapsedUs(requestStartNs);
                double cElapsed = requestLatencyUs / 1000.0;

                appendLine(topicOpsCsv, String.format(
                    "%s,%d,produce,%s,%d,%s,%.3f,%s,%s",
                    nowIsoMs(), nowEpochMs(), topicName, createdCount, localPhase, cElapsed, cStatus, esc(cErr)
                ));
                appendLine(topicCreateRequestsCsv, String.format(
                    "%d,%s,%d,%d,%d,%d,%s,%s",
                    createdCount, topicName, requestLatencyUs, e2eLatencyUs,
                    onMetadataDurationUs, produceDurationUs, reqStatus, esc(reqErr)
                ));
                double brokerMetadataUpdateMs = brokerMetadataLogTracker.latestForTopic(topicName);
                String brokerMetadataUpdateMsStr = Double.isNaN(brokerMetadataUpdateMs)
                    ? ""
                    : String.format("%.3f", brokerMetadataUpdateMs);
                String e2eStatus = ("ok".equals(cStatus) && !Double.isNaN(brokerMetadataUpdateMs)) ? "ok" : "error";
                String e2eErr = "";
                if (!"ok".equals(cStatus)) {
                    e2eErr = cErr;
                } else if (Double.isNaN(brokerMetadataUpdateMs)) {
                    e2eErr = "broker-metadata-update-time-not-found-in-log";
                }
                appendLine(e2eCsv, String.format(
                    "%s,%d,%s,%s,%.4f,%s,%s,%s",
                    nowIsoMs(), nowEpochMs(), topicName, localPhase, e2eLatencyUs / 1000.0,
                    brokerMetadataUpdateMsStr, e2eStatus, esc(e2eErr)
                ));
                System.out.printf("PRODUCE topic=%s idx=%d phase=%s status=%s elapsed_ms=%.3f%n",
                    topicName, createdCount, localPhase, cStatus, cElapsed);

                if (!startedDelete && createdCount >= createOnlyCount) {
                    startedDelete = true;
                    writePhase(phaseFile, "create_delete");
                    if (phase2DurationSec >= 0) {
                        phase2EndMs = nowEpochMs() + (phase2DurationSec * 1000L);
                    }
                    appendLine(eventsCsv, String.format(
                        "%s,%d,created_%d_reached,%d,%d,create_delete,-",
                        nowIsoMs(), nowEpochMs(), createOnlyCount, createdCount, deletedCount
                    ));
                    System.out.printf("Reached created_count=%d; delete loop is now active%n", createdCount);
                    if (phase2DurationSec >= 0) {
                        System.out.printf("Phase2 timer started: %d seconds%n", phase2DurationSec);
                    }
                }

                if (startedDelete && deleteIdx <= createdCount) {
                    String delTopic = topicPrefix + deleteIdx;
                    int deleteRequestIdx = deleteIdx;

                    long dStart = nowEpochMs();
                    String dStatus = "ok";
                    String dErr = "";
                    try {
                        admin.deleteTopics(Collections.singletonList(delTopic)).all().get();
                    } catch (Exception e) {
                        dStatus = "error";
                        dErr = "delete-failed:" + esc(e.getMessage());
                    }
                    double dElapsed = (nowEpochMs() - dStart);

                    if ("ok".equals(dStatus)) {
                        deletedCount += 1;
                        deleteIdx += 1;
                    }

                    appendLine(topicOpsCsv, String.format(
                        "%s,%d,delete,%s,%d,create_delete,%.3f,%s,%s",
                        nowIsoMs(), nowEpochMs(), delTopic, deleteRequestIdx, dElapsed, dStatus, esc(dErr)
                    ));
                    System.out.printf("DELETE topic=%s idx=%d phase=create_delete status=%s elapsed_ms=%.3f%n",
                        delTopic, deleteRequestIdx, dStatus, dElapsed);
                }

            }
        }

        appendLine(eventsCsv, String.format(
            "%s,%d,experiment_end,%d,%d,%s,-",
            nowIsoMs(), nowEpochMs(), createdCount, deletedCount,
            phaseForCreatedCount(createdCount, createOnlyCount)
        ));

        System.out.printf("SUMMARY created=%d deleted=%d%n", createdCount, deletedCount);
    }
}
