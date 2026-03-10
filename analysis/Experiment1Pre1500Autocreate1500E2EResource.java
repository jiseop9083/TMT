import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.clients.producer.RecordMetadata;

import java.awt.BasicStroke;
import java.awt.Color;
import java.awt.Font;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.image.BufferedImage;
import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Properties;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

import javax.imageio.ImageIO;

public class Experiment1Pre1500Autocreate1500E2EResource {
    static class Args {
        String bootstrapServer = "localhost:9092";
        String kafkaBin = "./kafka-4.2/bin";
        String serverConfig = "./kafka-4.2/config/server.properties";
        String diskPath = ".";
        Long brokerPid = null;
        double startupTimeout = 60.0;
        double interval = 1.0;
        double postSeconds = 0.0;
        int produceCount = 1500;
        String producePrefix = "exp1-new-topic";
        int partitions = 1;
        short replicationFactor = 1;
        int messageBytes = 1;
        int producerCount = 1;
        double requestTimeoutSec = 30.0;
        boolean skipBrokerReset = false;
        Integer brokerLogFlushIntervalMs = null;
        Integer brokerLogSegmentDeleteDelayMs = 1000;
        Integer brokerFileDeleteDelayMs = 1000;
        Integer brokerLogRetentionCheckIntervalMs = 5000;
        String outputPrefix = null;
    }

    static class ResourceSample {
        final double elapsedSec;
        final double cpuPercent;
        final double memoryMb;
        final double diskPercent;
        final String phase;

        ResourceSample(double elapsedSec, double cpuPercent, double memoryMb, double diskPercent, String phase) {
            this.elapsedSec = elapsedSec;
            this.cpuPercent = cpuPercent;
            this.memoryMb = memoryMb;
            this.diskPercent = diskPercent;
            this.phase = phase;
        }
    }

    static class E2ESample {
        final int seq;
        final String topic;
        final double e2eMs;
        final double elapsedSec;

        E2ESample(int seq, String topic, double e2eMs, double elapsedSec) {
            this.seq = seq;
            this.topic = topic;
            this.e2eMs = e2eMs;
            this.elapsedSec = elapsedSec;
        }
    }

    static class ProcessMetrics {
        final double cpuPercent;
        final double rssMb;

        ProcessMetrics(double cpuPercent, double rssMb) {
            this.cpuPercent = cpuPercent;
            this.rssMb = rssMb;
        }
    }

    public static void main(String[] argv) throws Exception {
        System.setProperty("java.awt.headless", "true");
        Args args = parseArgs(argv);

        Path kafkaHome = Paths.get(args.kafkaBin).toAbsolutePath().normalize().getParent();
        Path diskPath = Paths.get(args.diskPath).toAbsolutePath().normalize();
        Path serverConfig = Paths.get(args.serverConfig).toAbsolutePath().normalize();

        if (!Files.exists(diskPath)) {
            throw new IllegalArgumentException("disk path does not exist: " + diskPath);
        }
        if (!Files.exists(serverConfig)) {
            throw new IllegalArgumentException("server config not found: " + serverConfig);
        }

        Path runtimeServerConfig = buildServerConfigWithOverrides(
                serverConfig,
                args.brokerLogFlushIntervalMs,
                args.brokerLogSegmentDeleteDelayMs,
                args.brokerFileDeleteDelayMs,
                args.brokerLogRetentionCheckIntervalMs
        );
        Path tempServerConfig = runtimeServerConfig.equals(serverConfig) ? null : runtimeServerConfig;
        if (tempServerConfig != null) {
            System.out.println("[INFO] using temporary server config overrides: " + tempServerConfig);
        }

        List<Path> logDirs = parseLogDirsFromConfig(runtimeServerConfig);
        if (logDirs.isEmpty()) {
            throw new IllegalStateException("no log dirs found in " + runtimeServerConfig);
        }

        String[] hostPort = parseBootstrapHostPort(args.bootstrapServer);
        String host = hostPort[0];
        int port = Integer.parseInt(hostPort[1]);

        if (!args.skipBrokerReset) {
            System.out.println("[INFO] stopping kafka broker");
            stopKafka(kafkaHome);
            System.out.println("[INFO] cleaning log dirs: " + joinPaths(logDirs));
            cleanLogDirs(logDirs);
            String clusterId = formatStorage(kafkaHome, runtimeServerConfig);
            System.out.println("[INFO] storage formatted. cluster id: " + clusterId);
            String ts = nowTs();
            Path brokerLog = Paths.get("broker_start_" + ts + ".log").toAbsolutePath().normalize();
            Process started = startKafka(kafkaHome, runtimeServerConfig, brokerLog);
            System.out.println("[INFO] broker start requested (pid=" + started.pid() + "), log: " + brokerLog);
            waitForPort(host, port, args.startupTimeout);
            sleepSec(5.0);
            System.out.println("[INFO] broker is ready on " + host + ":" + port);
        }

        long brokerPid = findBrokerPid(args.brokerPid);
        System.out.println("[INFO] broker PID for monitoring: " + brokerPid);

        String ts = nowTs();
        String prefix = args.outputPrefix != null
                ? args.outputPrefix
                : "analysis/exp1_pre1500_autocreate1500_" + ts;

        Path e2eCsv = Paths.get(prefix + "_e2e.csv").toAbsolutePath().normalize();
        Path e2ePng = Paths.get(prefix + "_e2e.png").toAbsolutePath().normalize();
        Path resCsv = Paths.get(prefix + "_resource.csv").toAbsolutePath().normalize();
        Path resPng = Paths.get(prefix + "_resource.png").toAbsolutePath().normalize();

        AtomicReference<String> phase = new AtomicReference<>("init");
        AtomicBoolean stopEvent = new AtomicBoolean(false);
        List<ResourceSample> resourceSamples = new ArrayList<>();
        long originNs = System.nanoTime();

        Runtime.getRuntime().addShutdownHook(new Thread(() -> stopEvent.set(true)));

        Thread monitorThread = new Thread(() -> monitorLoop(
                brokerPid,
                diskPath,
                args.interval,
                stopEvent,
                resourceSamples,
                phase,
                originNs
        ));
        monitorThread.setDaemon(true);
        monitorThread.start();

        List<E2ESample> e2eRecords = new ArrayList<>();
        try {
            phase.set("produce_auto_create");
            e2eRecords = produceWithE2E(
                    args.bootstrapServer,
                    args.producePrefix,
                    args.produceCount,
                    args.messageBytes,
                    args.producerCount,
                    args.requestTimeoutSec,
                    originNs
            );

            if (args.postSeconds > 0) {
                phase.set("post");
                System.out.println("[INFO] post monitor wait: " + args.postSeconds + "s");
                sleepSec(args.postSeconds);
            }
        } finally {
            stopEvent.set(true);
            monitorThread.join(TimeUnit.SECONDS.toMillis(5));
        }

        if (resourceSamples.isEmpty()) {
            throw new IllegalStateException("No resource samples collected.");
        }
        if (e2eRecords.isEmpty()) {
            throw new IllegalStateException("No E2E samples collected.");
        }

        ensureParent(e2eCsv);
        ensureParent(e2ePng);
        ensureParent(resCsv);
        ensureParent(resPng);

        saveE2ECsv(e2eCsv, e2eRecords);
        saveE2EPlot(e2ePng, e2eRecords, "Experiment 1 - E2E per Produce (X: count, Y: E2E ms)");
        saveResourceCsv(resCsv, resourceSamples);
        saveResourcePlot(resPng, resourceSamples, "Experiment 1 - Broker Resource Usage");

        System.out.println("[DONE] e2e csv: " + e2eCsv);
        System.out.println("[DONE] e2e plot: " + e2ePng);
        System.out.println("[DONE] resource csv: " + resCsv);
        System.out.println("[DONE] resource plot: " + resPng);

        if (tempServerConfig != null) {
            try {
                Files.deleteIfExists(tempServerConfig);
            } catch (IOException e) {
                System.out.println("[WARN] failed to remove temporary server config " + tempServerConfig + ": " + e.getMessage());
            }
        }
    }

    static Args parseArgs(String[] argv) {
        Args args = new Args();
        Map<String, String> kv = new HashMap<>();
        for (int i = 0; i < argv.length; i++) {
            String key = argv[i];
            if (!key.startsWith("--")) {
                throw new IllegalArgumentException("Unknown argument: " + key);
            }
            if ("--skip-broker-reset".equals(key)) {
                kv.put(key, "true");
                continue;
            }
            if (i + 1 >= argv.length) {
                throw new IllegalArgumentException("Missing value for " + key);
            }
            kv.put(key, argv[++i]);
        }

        args.bootstrapServer = kv.getOrDefault("--bootstrap-server", args.bootstrapServer);
        args.kafkaBin = kv.getOrDefault("--kafka-bin", args.kafkaBin);
        args.serverConfig = kv.getOrDefault("--server-config", args.serverConfig);
        args.diskPath = kv.getOrDefault("--disk-path", args.diskPath);
        if (kv.containsKey("--broker-pid")) args.brokerPid = Long.parseLong(kv.get("--broker-pid"));
        if (kv.containsKey("--startup-timeout")) args.startupTimeout = Double.parseDouble(kv.get("--startup-timeout"));
        if (kv.containsKey("--interval")) args.interval = Double.parseDouble(kv.get("--interval"));
        if (kv.containsKey("--post-seconds")) args.postSeconds = Double.parseDouble(kv.get("--post-seconds"));
        if (kv.containsKey("--produce-count")) args.produceCount = Integer.parseInt(kv.get("--produce-count"));
        args.producePrefix = kv.getOrDefault("--produce-prefix", args.producePrefix);
        if (kv.containsKey("--partitions")) args.partitions = Integer.parseInt(kv.get("--partitions"));
        if (kv.containsKey("--replication-factor")) args.replicationFactor = Short.parseShort(kv.get("--replication-factor"));
        if (kv.containsKey("--message-bytes")) args.messageBytes = Integer.parseInt(kv.get("--message-bytes"));
        if (kv.containsKey("--producer-count")) args.producerCount = Integer.parseInt(kv.get("--producer-count"));
        if (kv.containsKey("--request-timeout-sec")) args.requestTimeoutSec = Double.parseDouble(kv.get("--request-timeout-sec"));
        args.skipBrokerReset = Boolean.parseBoolean(kv.getOrDefault("--skip-broker-reset", "false"));
        if (kv.containsKey("--broker-log-flush-interval-ms")) args.brokerLogFlushIntervalMs = Integer.parseInt(kv.get("--broker-log-flush-interval-ms"));
        if (kv.containsKey("--broker-log-segment-delete-delay-ms")) args.brokerLogSegmentDeleteDelayMs = Integer.parseInt(kv.get("--broker-log-segment-delete-delay-ms"));
        if (kv.containsKey("--broker-file-delete-delay-ms")) args.brokerFileDeleteDelayMs = Integer.parseInt(kv.get("--broker-file-delete-delay-ms"));
        if (kv.containsKey("--broker-log-retention-check-interval-ms")) args.brokerLogRetentionCheckIntervalMs = Integer.parseInt(kv.get("--broker-log-retention-check-interval-ms"));
        if (kv.containsKey("--output-prefix")) args.outputPrefix = kv.get("--output-prefix");

        return args;
    }

    static List<Path> parseLogDirsFromConfig(Path configPath) throws IOException {
        List<Path> result = new ArrayList<>();
        List<String> lines = Files.readAllLines(configPath, StandardCharsets.UTF_8);
        for (String raw : lines) {
            String line = raw.trim();
            if (line.isEmpty() || line.startsWith("#") || !line.contains("=")) continue;
            int p = line.indexOf('=');
            String key = line.substring(0, p).trim();
            String value = line.substring(p + 1).trim();
            if ((!"log.dirs".equals(key) && !"metadata.log.dir".equals(key)) || value.isEmpty()) continue;
            for (String item : value.split(",")) {
                String d = item.trim();
                if (!d.isEmpty()) result.add(Paths.get(d).toAbsolutePath().normalize());
            }
        }
        List<Path> uniq = new ArrayList<>();
        for (Path p : result) {
            if (!uniq.contains(p)) uniq.add(p);
        }
        return uniq;
    }

    static void stopKafka(Path kafkaHome) throws IOException, InterruptedException {
        runCommand(List.of(kafkaHome.resolve("bin/kafka-server-stop.sh").toString()), null, false);
        sleepSec(5.0);
        runCommand(List.of("pkill", "-f", "kafka.Kafka"), null, false);
        sleepSec(2.0);
    }

    static void cleanLogDirs(List<Path> logDirs) {
        for (Path p : logDirs) {
            try {
                runCommand(List.of("rm", "-rf", p.toString()), null, false);
            } catch (Exception ignored) {
            }
        }
    }

    static String formatStorage(Path kafkaHome, Path serverConfig) throws IOException, InterruptedException {
        CommandResult uuid = runCommand(
                List.of(kafkaHome.resolve("bin/kafka-storage.sh").toString(), "random-uuid"),
                null,
                true
        );
        String clusterId = uuid.stdout.trim();
        runCommand(List.of(
                kafkaHome.resolve("bin/kafka-storage.sh").toString(),
                "format",
                "--standalone",
                "-t", clusterId,
                "-c", serverConfig.toString()
        ), null, true);
        return clusterId;
    }

    static Process startKafka(Path kafkaHome, Path serverConfig, Path brokerLog) throws IOException {
        ensureParent(brokerLog);
        ProcessBuilder pb = new ProcessBuilder(
                kafkaHome.resolve("bin/kafka-server-start.sh").toString(),
                serverConfig.toString()
        );
        pb.redirectErrorStream(true);
        pb.redirectOutput(ProcessBuilder.Redirect.appendTo(brokerLog.toFile()));
        return pb.start();
    }

    static String[] parseBootstrapHostPort(String bootstrapServer) {
        String first = bootstrapServer.split(",")[0].trim();
        int idx = first.lastIndexOf(':');
        if (idx <= 0 || idx + 1 >= first.length()) {
            throw new IllegalArgumentException("invalid --bootstrap-server format: " + bootstrapServer);
        }
        return new String[]{first.substring(0, idx), first.substring(idx + 1)};
    }

    static void waitForPort(String host, int port, double timeoutSec) {
        long deadline = System.nanoTime() + (long) (timeoutSec * 1_000_000_000L);
        while (System.nanoTime() < deadline) {
            try (java.net.Socket socket = new java.net.Socket()) {
                socket.connect(new java.net.InetSocketAddress(host, port), 2000);
                return;
            } catch (IOException ignored) {
                sleepSec(2.0);
            }
        }
        throw new RuntimeException("broker not ready on " + host + ":" + port + " within " + timeoutSec + "s");
    }

    static long findBrokerPid(Long userPid) throws IOException, InterruptedException {
        if (userPid != null) {
            Optional<ProcessHandle> ph = ProcessHandle.of(userPid);
            if (ph.isEmpty() || !ph.get().isAlive()) {
                throw new RuntimeException("PID " + userPid + " is not running");
            }
            return userPid;
        }
        CommandResult cr = runCommand(List.of("pgrep", "-f", "kafka\\.Kafka|kafka-server-start"), null, false);
        if (cr.exitCode != 0 || cr.stdout.trim().isEmpty()) {
            throw new RuntimeException("Kafka broker process not found.");
        }
        String first = cr.stdout.trim().split("\\R")[0].trim();
        return Long.parseLong(first);
    }

    static Path buildServerConfigWithOverrides(
            Path baseConfig,
            Integer flushIntervalMs,
            Integer logSegmentDeleteDelayMs,
            Integer fileDeleteDelayMs,
            Integer logRetentionCheckIntervalMs
    ) throws IOException {
        if (flushIntervalMs == null && logSegmentDeleteDelayMs == null && fileDeleteDelayMs == null && logRetentionCheckIntervalMs == null) {
            return baseConfig;
        }
        String content = Files.readString(baseConfig, StandardCharsets.UTF_8);
        Path tmp = Files.createTempFile("server_overrides_", ".properties");
        StringBuilder sb = new StringBuilder(content);
        if (!content.endsWith("\n")) sb.append("\n");
        sb.append("\n# temporary overrides from experiment1 script\n");
        if (flushIntervalMs != null) sb.append("log.flush.interval.ms=").append(flushIntervalMs).append("\n");
        if (logSegmentDeleteDelayMs != null) sb.append("log.segment.delete.delay.ms=").append(logSegmentDeleteDelayMs).append("\n");
        if (fileDeleteDelayMs != null) sb.append("file.delete.delay.ms=").append(fileDeleteDelayMs).append("\n");
        if (logRetentionCheckIntervalMs != null) sb.append("log.retention.check.interval.ms=").append(logRetentionCheckIntervalMs).append("\n");
        Files.writeString(tmp, sb.toString(), StandardCharsets.UTF_8);
        return tmp;
    }

    static List<E2ESample> produceWithE2E(
            String bootstrap,
            String prefix,
            int count,
            int messageBytes,
            int producerCount,
            double requestTimeoutSec,
            long originNs
    ) throws ExecutionException, InterruptedException, TimeoutException {
        if (producerCount < 1) {
            throw new IllegalArgumentException("--producer-count must be >= 1");
        }

        byte[] payload = new byte[Math.max(1, messageBytes)];
        for (int i = 0; i < payload.length; i++) payload[i] = 'x';

        List<KafkaProducer<String, byte[]>> producers = new ArrayList<>();
        for (int i = 0; i < producerCount; i++) {
            Properties props = new Properties();
            props.put("bootstrap.servers", bootstrap);
            props.put("acks", "1");
            props.put("retries", "3");
            props.put("request.timeout.ms", Integer.toString((int) (requestTimeoutSec * 1000)));
            props.put("client.id", "exp1-producer-" + (i + 1));
            props.put("key.serializer", "org.apache.kafka.common.serialization.StringSerializer");
            props.put("value.serializer", "org.apache.kafka.common.serialization.ByteArraySerializer");
            producers.add(new KafkaProducer<>(props));
        }

        List<E2ESample> records = new ArrayList<>();
        try {
            for (int i = 1; i <= count; i++) {
                String topic = String.format("%s-%04d", prefix, i);
                KafkaProducer<String, byte[]> producer = producers.get((i - 1) % producerCount);
                long t0 = System.nanoTime();
                RecordMetadata md = producer.send(new ProducerRecord<>(topic, payload))
                        .get((long) requestTimeoutSec, TimeUnit.SECONDS);
                if (md == null) {
                    throw new RuntimeException("send returned null metadata for topic " + topic);
                }
                double e2eMs = (System.nanoTime() - t0) / 1_000_000.0;
                double elapsedSec = elapsedFromNs(originNs);
                records.add(new E2ESample(i, topic, e2eMs, elapsedSec));
                if (i % 100 == 0 || i == count) {
                    System.out.println("[INFO] produce progress: " + i + "/" + count);
                }
            }
        } finally {
            for (KafkaProducer<String, byte[]> p : producers) {
                try {
                    p.flush();
                    p.close(java.time.Duration.ofMillis((long) (requestTimeoutSec * 1000)));
                } catch (Exception ignored) {
                }
            }
        }
        return records;
    }

    static void monitorLoop(
            long brokerPid,
            Path diskPath,
            double intervalSec,
            AtomicBoolean stopEvent,
            List<ResourceSample> samples,
            AtomicReference<String> phase,
            long originNs
    ) {
        while (!stopEvent.get()) {
            try {
                ProcessMetrics pm = readProcessMetrics(brokerPid);
                double diskPct = readDiskPercent(diskPath);
                synchronized (samples) {
                    samples.add(new ResourceSample(elapsedFromNs(originNs), pm.cpuPercent, pm.rssMb, diskPct, phase.get()));
                }
            } catch (Exception ignored) {
                break;
            }
            sleepSec(intervalSec);
        }
    }

    static ProcessMetrics readProcessMetrics(long pid) throws IOException, InterruptedException {
        CommandResult cr = runCommand(List.of("ps", "-p", Long.toString(pid), "-o", "%cpu=,rss="), null, true);
        String line = cr.stdout.trim();
        if (line.isEmpty()) {
            throw new RuntimeException("broker process not found: " + pid);
        }
        String[] parts = line.trim().split("\\s+");
        if (parts.length < 2) {
            throw new RuntimeException("unexpected ps output: " + line);
        }
        double cpu = Double.parseDouble(parts[0]);
        double rssMb = Double.parseDouble(parts[1]) / 1024.0;
        return new ProcessMetrics(cpu, rssMb);
    }

    static double readDiskPercent(Path diskPath) throws IOException, InterruptedException {
        CommandResult cr = runCommand(List.of("df", "-k", diskPath.toString()), null, true);
        String[] lines = cr.stdout.split("\\R");
        if (lines.length < 2) return 0.0;
        String[] cols = lines[1].trim().split("\\s+");
        if (cols.length < 5) return 0.0;
        String use = cols[4].replace("%", "");
        return Double.parseDouble(use);
    }

    static void saveResourceCsv(Path path, List<ResourceSample> samples) throws IOException {
        try (BufferedWriter w = Files.newBufferedWriter(path, StandardCharsets.UTF_8)) {
            w.write("elapsed_sec,cpu_percent,memory_mb,disk_percent,phase\n");
            synchronized (samples) {
                for (ResourceSample s : samples) {
                    w.write(String.format(java.util.Locale.US, "%.3f,%.3f,%.3f,%.3f,%s%n",
                            s.elapsedSec, s.cpuPercent, s.memoryMb, s.diskPercent, s.phase));
                }
            }
        }
    }

    static void saveE2ECsv(Path path, List<E2ESample> records) throws IOException {
        try (BufferedWriter w = Files.newBufferedWriter(path, StandardCharsets.UTF_8)) {
            w.write("seq,topic,e2e_ms,elapsed_sec\n");
            for (E2ESample r : records) {
                w.write(String.format(java.util.Locale.US, "%d,%s,%.3f,%.3f%n", r.seq, r.topic, r.e2eMs, r.elapsedSec));
            }
        }
    }

    static void saveResourcePlot(Path path, List<ResourceSample> samples, String title) throws IOException {
        int width = 1400;
        int height = 1000;
        int left = 80;
        int right = 30;
        int top = 50;
        int panelGap = 20;
        int panelHeight = (height - top - 50 - panelGap * 2) / 3;

        List<ResourceSample> copy;
        synchronized (samples) {
            copy = new ArrayList<>(samples);
        }

        double maxX = copy.stream().mapToDouble(s -> s.elapsedSec).max().orElse(1.0);
        double maxCpu = Math.max(100.0, copy.stream().mapToDouble(s -> s.cpuPercent).max().orElse(100.0));
        double maxMem = copy.stream().mapToDouble(s -> s.memoryMb).max().orElse(1.0) * 1.1;
        double maxDisk = 100.0;

        BufferedImage img = new BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = img.createGraphics();
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
        g.setColor(Color.WHITE);
        g.fillRect(0, 0, width, height);
        g.setFont(new Font("SansSerif", Font.BOLD, 18));
        g.setColor(Color.BLACK);
        g.drawString(title, left, 30);

        drawLinePanel(g, copy, left, top, width - left - right, panelHeight, maxX, maxCpu,
                s -> s.cpuPercent, new Color(0xd6, 0x27, 0x28), "CPU (%)", false);
        drawLinePanel(g, copy, left, top + panelHeight + panelGap, width - left - right, panelHeight, maxX, maxMem,
                s -> s.memoryMb, new Color(0x1f, 0x77, 0xb4), "Memory (MB)", false);
        drawLinePanel(g, copy, left, top + (panelHeight + panelGap) * 2, width - left - right, panelHeight, maxX, maxDisk,
                s -> s.diskPercent, new Color(0x2c, 0xa0, 0x2c), "Disk (%)", true);

        g.dispose();
        ImageIO.write(img, "png", path.toFile());
    }

    interface YFn {
        double get(ResourceSample s);
    }

    static void drawLinePanel(Graphics2D g,
                              List<ResourceSample> samples,
                              int x,
                              int y,
                              int w,
                              int h,
                              double maxX,
                              double maxY,
                              YFn yFn,
                              Color lineColor,
                              String yLabel,
                              boolean drawXLabel) {
        g.setColor(new Color(245, 245, 245));
        g.fillRect(x, y, w, h);
        g.setColor(Color.GRAY);
        g.drawRect(x, y, w, h);
        g.setFont(new Font("SansSerif", Font.PLAIN, 12));
        g.setColor(Color.BLACK);
        g.drawString(yLabel, x + 8, y + 16);

        g.setColor(new Color(220, 220, 220));
        for (int i = 1; i <= 4; i++) {
            int gy = y + (h * i / 5);
            g.drawLine(x, gy, x + w, gy);
        }

        g.setColor(lineColor);
        g.setStroke(new BasicStroke(2f));
        for (int i = 1; i < samples.size(); i++) {
            ResourceSample a = samples.get(i - 1);
            ResourceSample b = samples.get(i);
            int x1 = x + (int) Math.round((a.elapsedSec / Math.max(maxX, 1e-9)) * w);
            int y1 = y + h - (int) Math.round((Math.min(yFn.get(a), maxY) / Math.max(maxY, 1e-9)) * h);
            int x2 = x + (int) Math.round((b.elapsedSec / Math.max(maxX, 1e-9)) * w);
            int y2 = y + h - (int) Math.round((Math.min(yFn.get(b), maxY) / Math.max(maxY, 1e-9)) * h);
            g.drawLine(x1, y1, x2, y2);
        }

        g.setColor(Color.DARK_GRAY);
        g.drawString(String.format(java.util.Locale.US, "0"), x, y + h + 14);
        g.drawString(String.format(java.util.Locale.US, "%.1f", maxX), x + w - 35, y + h + 14);
        if (drawXLabel) {
            g.drawString("Elapsed Time (sec)", x + w / 2 - 50, y + h + 30);
        }
    }

    static void saveE2EPlot(Path path, List<E2ESample> records, String title) throws IOException {
        int width = 1400;
        int height = 550;
        int left = 80;
        int right = 30;
        int top = 50;
        int bottom = 70;

        int maxX = records.stream().mapToInt(r -> r.seq).max().orElse(1);
        double maxY = 200.0;

        BufferedImage img = new BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = img.createGraphics();
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
        g.setColor(Color.WHITE);
        g.fillRect(0, 0, width, height);

        int plotX = left;
        int plotY = top;
        int plotW = width - left - right;
        int plotH = height - top - bottom;

        g.setColor(new Color(245, 245, 245));
        g.fillRect(plotX, plotY, plotW, plotH);
        g.setColor(Color.GRAY);
        g.drawRect(plotX, plotY, plotW, plotH);

        g.setFont(new Font("SansSerif", Font.BOLD, 18));
        g.setColor(Color.BLACK);
        g.drawString(title, left, 30);

        g.setColor(new Color(220, 220, 220));
        for (int i = 1; i <= 4; i++) {
            int gy = plotY + (plotH * i / 5);
            g.drawLine(plotX, gy, plotX + plotW, gy);
        }

        g.setColor(new Color(0xff, 0x7f, 0x0e, 200));
        for (E2ESample r : records) {
            int px = plotX + (int) Math.round(((double) (r.seq - 1) / Math.max(maxX - 1, 1)) * plotW);
            double clipped = Math.max(0.0, Math.min(maxY, r.e2eMs));
            int py = plotY + plotH - (int) Math.round((clipped / maxY) * plotH);
            g.fillOval(px - 2, py - 2, 4, 4);
        }

        g.setColor(Color.BLACK);
        g.setFont(new Font("SansSerif", Font.PLAIN, 12));
        g.drawString("Produce Count", plotX + plotW / 2 - 40, height - 25);
        g.drawString("E2E (ms)", 20, plotY + plotH / 2);
        g.drawString("1", plotX, plotY + plotH + 15);
        g.drawString(Integer.toString(maxX), plotX + plotW - 30, plotY + plotH + 15);
        g.drawString("0", plotX - 20, plotY + plotH);
        g.drawString("200", plotX - 35, plotY + 10);

        g.dispose();
        ImageIO.write(img, "png", path.toFile());
    }

    static CommandResult runCommand(List<String> cmd, Path cwd, boolean check) throws IOException, InterruptedException {
        ProcessBuilder pb = new ProcessBuilder(cmd);
        if (cwd != null) pb.directory(cwd.toFile());
        Process p = pb.start();
        String stdout = readAll(p.getInputStream());
        String stderr = readAll(p.getErrorStream());
        int ec = p.waitFor();
        if (check && ec != 0) {
            throw new RuntimeException("command failed(" + ec + "): " + String.join(" ", cmd) + "\n" + stderr);
        }
        return new CommandResult(ec, stdout, stderr);
    }

    static String readAll(InputStream in) throws IOException {
        try (BufferedReader br = new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8))) {
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = br.readLine()) != null) {
                sb.append(line).append('\n');
            }
            return sb.toString();
        }
    }

    static class CommandResult {
        final int exitCode;
        final String stdout;
        final String stderr;

        CommandResult(int exitCode, String stdout, String stderr) {
            this.exitCode = exitCode;
            this.stdout = stdout;
            this.stderr = stderr;
        }
    }

    static void ensureParent(Path p) throws IOException {
        Path parent = p.getParent();
        if (parent != null) Files.createDirectories(parent);
    }

    static void sleepSec(double sec) {
        try {
            Thread.sleep((long) (sec * 1000));
        } catch (InterruptedException ignored) {
            Thread.currentThread().interrupt();
        }
    }

    static double elapsedFromNs(long originNs) {
        return (System.nanoTime() - originNs) / 1_000_000_000.0;
    }

    static String nowTs() {
        return LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyyMMdd_HHmmss"));
    }

    static String joinPaths(List<Path> paths) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < paths.size(); i++) {
            if (i > 0) sb.append(", ");
            sb.append(paths.get(i));
        }
        return sb.toString();
    }
}
