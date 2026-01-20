import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.time.Duration;
import java.util.*;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import jdk.jfr.consumer.RecordedEvent;
import jdk.jfr.consumer.RecordedFrame;
import jdk.jfr.consumer.RecordedStackTrace;
import jdk.jfr.consumer.RecordingFile;

public class JfrWallClockAttribution {

    // 집계할 이벤트들(대기/블로킹/IO)
    static final Set<String> TARGET_EVENTS = Set.of(
            "jdk.ThreadSleep",
            "jdk.ThreadPark",
            "jdk.JavaMonitorEnter",
            "jdk.JavaMonitorWait",
            "jdk.SocketRead",
            "jdk.SocketWrite",
            "jdk.SafePointWait"
    );
    static final Set<String> PRODUCER_METHODS = Set.of(
            "org.apache.kafka.clients.producer.KafkaProducer#doSend",
            "org.apache.kafka.clients.producer.KafkaProducer#waitOnMetadata",
            "org.apache.kafka.clients.producer.internals.RecordAccumulator#append",
            "org.apache.kafka.common.serialization.Serializer#serialize"
    );

    enum AttributionMode { TOP, BOTTOM, FIRST_APP_FRAME }

    static class MethodTotals {
        final Map<String, Long> methodNanos;
        final Map<String, Integer> methodCounts;

        MethodTotals(Map<String, Long> methodNanos, Map<String, Integer> methodCounts) {
            this.methodNanos = methodNanos;
            this.methodCounts = methodCounts;
        }
    }

    public static void main(String[] args) throws Exception {
        String outDirArg = "client_profile_job/out";
        AttributionMode mode = AttributionMode.FIRST_APP_FRAME;
        int topN = 50;

        for (int i = 0; i < args.length; i++) {
            String arg = args[i];
            if ("--out-dir".equals(arg) && i + 1 < args.length) {
                outDirArg = args[++i];
            } else if ("--mode".equals(arg) && i + 1 < args.length) {
                mode = switch (args[++i].toUpperCase(Locale.ROOT)) {
                    case "TOP" -> AttributionMode.TOP;
                    case "BOTTOM" -> AttributionMode.BOTTOM;
                    case "APP" -> AttributionMode.FIRST_APP_FRAME;
                    default -> throw new IllegalArgumentException("mode must be TOP|BOTTOM|APP");
                };
            } else if ("--top-n".equals(arg) && i + 1 < args.length) {
                topN = Integer.parseInt(args[++i]);
            } else if ("--help".equals(arg)) {
                System.out.println(
                        "Usage: java JfrWallClockAttribution --out-dir <dir> [--mode TOP|BOTTOM|APP] [--top-n N]");
                return;
            } else {
                throw new IllegalArgumentException("Unknown argument: " + arg);
            }
        }

        Path runDir = findRunDir(Paths.get(outDirArg));
        List<Path> expDirs = iterExperimentDirs(runDir);
        if (expDirs.isEmpty()) {
            throw new IllegalStateException("No experiment directories found under " + runDir);
        }

        Path analysisDir = runDir.resolve("analysis");
        Files.createDirectories(analysisDir);
        Path methodTimes = analysisDir.resolve("method_times.csv");

        try (BufferedWriter writer = Files.newBufferedWriter(methodTimes)) {
            writer.write("experiment_id,topic,topic_count,method,event_count,cpu_ms,wall_clock_ms,total_ms,run_dir");
            writer.newLine();

            for (Path expDir : expDirs) {
                Path jfrPath = findJfr(expDir);
                if (jfrPath == null) {
                    continue;
                }
                int experimentId = parseExperimentId(expDir.getFileName().toString());
                Map<String, String> metrics = readMetrics(expDir);
                String topic = metrics.getOrDefault("topic", "test_topic_" + experimentId);
                int topicCount = inferTopicCount(topic, experimentId);

                MethodTotals totals = parseWallClockTotals(jfrPath, mode);
                List<Map.Entry<String, Long>> sorted = new ArrayList<>(totals.methodNanos.entrySet());
                sorted.sort((a, b) -> Long.compare(b.getValue(), a.getValue()));
                int limit = topN > 0 ? Math.min(topN, sorted.size()) : sorted.size();

                for (int i = 0; i < limit; i++) {
                    Map.Entry<String, Long> ent = sorted.get(i);
                    String method = ent.getKey();
                    if (!PRODUCER_METHODS.contains(method)) {
                        continue;
                    }
                    double wallMs = ent.getValue() / 1_000_000.0;
                    int eventCount = totals.methodCounts.getOrDefault(method, 0);
                    writer.write(String.format(
                            Locale.ROOT,
                            "%d,%s,%d,%s,%d,%.3f,%.3f,%.3f,%s",
                            experimentId,
                            topic,
                            topicCount,
                            method,
                            eventCount,
                            0.0,
                            wallMs,
                            wallMs,
                            expDir.toString()
                    ));
                    writer.newLine();
                }
            }
        }

        System.out.println("Wrote analysis CSVs to " + analysisDir);
    }

    // APP 프레임 판정: 필요에 맞게 패키지 조건 조정
    static boolean isAppFrame(RecordedFrame f) {
        String cls = f.getMethod().getType().getName();
        return cls.startsWith("com.") || cls.startsWith("io.") || cls.startsWith("kr.");
    }

    static boolean isProducerFrame(RecordedFrame f) {
        String cls = f.getMethod().getType().getName();
        return cls.startsWith("org.apache.kafka.");
    }

    static String frameToMethodSig(RecordedFrame f) {
        String cls = f.getMethod().getType().getName();
        String m = f.getMethod().getName();
        return cls + "#" + m;
    }

    static String pickMethod(RecordedStackTrace st, AttributionMode mode) {
        List<RecordedFrame> frames = st.getFrames();
        if (frames == null || frames.isEmpty()) return null;

        return switch (mode) {
            case TOP -> frameToMethodSig(frames.get(0));
            case BOTTOM -> frameToMethodSig(frames.get(frames.size() - 1));
            case FIRST_APP_FRAME -> {
                for (RecordedFrame f : frames) {
                    if (isAppFrame(f) || isProducerFrame(f)) {
                        yield frameToMethodSig(f);
                    }
                }
                // 앱 프레임이 없으면 TOP으로 폴백
                yield frameToMethodSig(frames.get(0));
            }
        };
    }

    static MethodTotals parseWallClockTotals(Path jfr, AttributionMode mode) throws IOException {
        // (eventType, methodSig) -> totalNanos
        Map<String, Long> totals = new HashMap<>();
        Map<String, Integer> counts = new HashMap<>();

        try (RecordingFile rf = new RecordingFile(jfr)) {
            while (rf.hasMoreEvents()) {
                RecordedEvent e = rf.readEvent();
                String en = e.getEventType().getName();
                if (!TARGET_EVENTS.contains(en)) continue;

                // duration 필드가 있는 이벤트만
                Duration d;
                try {
                    d = e.getDuration();
                } catch (Exception ex) {
                    continue;
                }
                long nanos = d.toNanos();
                if (nanos <= 0) continue;

                RecordedStackTrace st = e.getStackTrace();
                if (st == null) continue;

                String method = pickMethod(st, mode);
                if (method == null) continue;

                String key = en + "\t" + method;
                totals.merge(key, nanos, Long::sum);
                counts.merge(key, 1, Integer::sum);
            }
        }

        Map<String, Long> methodTotals = new HashMap<>();
        Map<String, Integer> methodCounts = new HashMap<>();
        for (Map.Entry<String, Long> entry : totals.entrySet()) {
            String[] parts = entry.getKey().split("\t", 2);
            if (parts.length != 2) continue;
            String method = parts[1];
            methodTotals.merge(method, entry.getValue(), Long::sum);
        }
        for (Map.Entry<String, Integer> entry : counts.entrySet()) {
            String[] parts = entry.getKey().split("\t", 2);
            if (parts.length != 2) continue;
            String method = parts[1];
            methodCounts.merge(method, entry.getValue(), Integer::sum);
        }

        return new MethodTotals(methodTotals, methodCounts);
    }

    static Path findRunDir(Path base) throws IOException {
        if (Files.isDirectory(base) && base.getFileName().toString().startsWith("202")) {
            return base;
        }
        List<Path> candidates = new ArrayList<>();
        try (DirectoryStream<Path> stream = Files.newDirectoryStream(base)) {
            for (Path p : stream) {
                if (Files.isDirectory(p)) {
                    candidates.add(p);
                }
            }
        }
        candidates.sort(Comparator.naturalOrder());
        if (candidates.size() == 1) {
            return candidates.get(0);
        }
        if (candidates.size() > 1) {
            return candidates.get(candidates.size() - 1);
        }
        throw new IOException("No run directories found under " + base);
    }

    static List<Path> iterExperimentDirs(Path runDir) throws IOException {
        List<Path> dirs = new ArrayList<>();
        try (DirectoryStream<Path> stream = Files.newDirectoryStream(runDir)) {
            for (Path p : stream) {
                if (!Files.isDirectory(p)) continue;
                if (p.getFileName().toString().startsWith("kafka-producer-experiment-")) {
                    dirs.add(p);
                }
            }
        }
        dirs.sort(Comparator.comparingInt(p -> parseExperimentId(p.getFileName().toString())));
        return dirs;
    }

    static Path findJfr(Path expDir) throws IOException {
        Path candidate = findFirstMatching(expDir, "producer-", ".jfr");
        if (candidate != null) {
            return candidate;
        }
        return findFirstMatching(expDir, "", ".jfr");
    }

    static Path findFirstMatching(Path dir, String prefix, String suffix) throws IOException {
        List<Path> matches = new ArrayList<>();
        try (DirectoryStream<Path> stream = Files.newDirectoryStream(dir)) {
            for (Path p : stream) {
                String name = p.getFileName().toString();
                if (!Files.isRegularFile(p)) continue;
                if (!name.startsWith(prefix) || !name.endsWith(suffix)) continue;
                matches.add(p);
            }
        }
        matches.sort(Comparator.naturalOrder());
        return matches.isEmpty() ? null : matches.get(0);
    }

    static Map<String, String> readMetrics(Path expDir) throws IOException {
        Path metricsPath = findFirstMatching(expDir, "metrics-", ".txt");
        if (metricsPath == null) {
            metricsPath = expDir.resolve("metrics.txt");
            if (!Files.exists(metricsPath)) {
                return Collections.emptyMap();
            }
        }
        Map<String, String> data = new HashMap<>();
        List<String> lines = Files.readAllLines(metricsPath);
        for (String line : lines) {
            String trimmed = line.trim();
            if (trimmed.isEmpty()) continue;
            int idx = trimmed.indexOf('=');
            if (idx <= 0) continue;
            String key = trimmed.substring(0, idx).trim();
            String value = trimmed.substring(idx + 1).trim();
            data.put(key, value);
        }
        return data;
    }

    static int parseExperimentId(String name) {
        int idx = name.lastIndexOf('-');
        if (idx < 0 || idx + 1 >= name.length()) return 0;
        try {
            return Integer.parseInt(name.substring(idx + 1));
        } catch (NumberFormatException ex) {
            return 0;
        }
    }

    static int inferTopicCount(String topic, int fallback) {
        Pattern pattern = Pattern.compile("(\\d+)$");
        Matcher matcher = pattern.matcher(topic);
        if (matcher.find()) {
            return Integer.parseInt(matcher.group(1));
        }
        return fallback;
    }
}
