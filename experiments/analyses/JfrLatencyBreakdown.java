import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;
import jdk.jfr.consumer.RecordedEvent;
import jdk.jfr.consumer.RecordedFrame;
import jdk.jfr.consumer.RecordedStackTrace;
import jdk.jfr.consumer.RecordingFile;

public class JfrLatencyBreakdown {

    // 분석에 포함할 JFR 이벤트 목록
    static final Set<String> TARGET_EVENTS = Set.of(
            "jdk.ThreadPark",
            "jdk.JavaMonitorEnter",
            "jdk.JavaMonitorWait",
            "jdk.SocketRead",
            "jdk.SocketWrite",
            "jdk.ExecutionSample",
            "jdk.CPULoad",
            "jdk.ObjectAllocationInNewTLAB",
            "jdk.ObjectAllocationOutsideTLAB",
            "jdk.GCPhasePause",
            "jdk.SafePointWait"
    );
    static final String WAIT_ON_METADATA_METHOD =
            "org.apache.kafka.clients.producer.KafkaProducer#waitOnMetadata";
    static final String FUTURE_RECORD_METADATA_CLASS =
            "org.apache.kafka.clients.producer.internals.FutureRecordMetadata";
    static final Pattern PRODUCER_ID_PATTERN = Pattern.compile("producer-(\\d+)");

    // 이벤트 집계 결과를 담는 구조체
    static class EventTotals {
        long waitOnMetadataNanos;
        long produceCompletionNanos;
        long socketReadNanos;
        int socketReadCount;
        long socketWriteNanos;
        int socketWriteCount;
        int executionSampleCount;
        int allocSamplesInTlabCount;
        int allocSamplesOutsideTlabCount;
        long gcPauseNanos;
        long safepointWaitNanos;
        long adminClientMonitorBlockNanos;
        long producerMonitorBlockNanos;
        final List<Double> cpuMachineTotals = new ArrayList<>();
    }

    static class TopicTotals {
        long waitOnMetadataNanos;
        long produceCompletionNanos;
    }

    // 실행 디렉터리의 JFR을 집계하고 CSV로 저장한다
    public static void main(String[] args) throws Exception {
        String outDirArg = "client_profile_job/out";

        for (int i = 0; i < args.length; i++) {
            String arg = args[i];
            if ("--out-dir".equals(arg) && i + 1 < args.length) {
                outDirArg = args[++i];
            } else if ("--help".equals(arg)) {
                System.out.println(
                        "Usage: java JfrLatencyBreakdown --out-dir <dir>");
                return;
            } else {
                throw new IllegalArgumentException("Unknown argument: " + arg);
            }
        }

        Path runDir = findRunDir(Paths.get(outDirArg));

        Path analysisDir = runDir.resolve("analysis");
        Path jsonDir = analysisDir.resolve("json");
        Files.createDirectories(jsonDir);
        Path latencyCsv = analysisDir.resolve("latency_breakdown.csv");

        List<Path> expDirs = iterExperimentDirs(runDir);
        if (expDirs.isEmpty()) {
            writeSingleRunCsv(latencyCsv, runDir, jsonDir);
            System.out.println("Wrote analysis CSVs to " + analysisDir);
            return;
        }

        try (BufferedWriter writer = Files.newBufferedWriter(latencyCsv)) {
            writer.write("topic,topic_count,producer_e2e_ms,produce_completion_ms,e2e_completion_remainder_ms,wait_on_metadata_ms,");
            writer.write("socket_read_sender_ms,socket_read_sender_count,socket_write_sender_ms,");
            writer.write("socket_write_sender_count,gc_pause_ms,");
            writer.write("safepoint_wait_ms,admin_client_monitor_block_ms,producer_monitor_block_ms,");
            writer.write("alloc_samples_in_tlab_count,alloc_samples_outside_tlab_count,outside_tlab_ratio,");
            writer.write("sender_cpu_samples,");
            writer.write("cpu_machine_avg,cpu_machine_p95,cpu_machine_max,run_dir");
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
                String producerE2eRaw = metrics.getOrDefault("send_ack_ms_1", "");
                double producerE2e = parseDoublePrefix(producerE2eRaw);

                String baseName = baseName(jfrPath.getFileName().toString());
                Path jsonPath = jsonDir.resolve(expDir.getFileName() + "-" + baseName + "-events.jsonl");
                writeEventsJson(jfrPath, jsonPath);
                EventTotals totals = parseEventsJson(jsonPath);

                double produceCompletionMs = nanosToMs(totals.produceCompletionNanos);
                double e2eMinusCompletionMs = producerE2e - produceCompletionMs;
                writer.write(String.format(
                        Locale.ROOT,
                        "%s,%d,%.3f,%.3f,%.3f,%.3f,%d,%.3f,%d,%.3f,%.3f,%.3f,%.3f,%d,%d,%.6f,%d,%.6f,%.6f,%.6f,%s",
                        topic,
                        topicCount,
                        producerE2e,
                        produceCompletionMs,
                        e2eMinusCompletionMs,
                        nanosToMs(totals.waitOnMetadataNanos),
                        nanosToMs(totals.socketReadNanos),
                        totals.socketReadCount,
                        nanosToMs(totals.socketWriteNanos),
                        totals.socketWriteCount,
                        nanosToMs(totals.gcPauseNanos),
                        nanosToMs(totals.safepointWaitNanos),
                        nanosToMs(totals.adminClientMonitorBlockNanos),
                        nanosToMs(totals.producerMonitorBlockNanos),
                        totals.allocSamplesInTlabCount,
                        totals.allocSamplesOutsideTlabCount,
                        outsideTlabRatio(totals.allocSamplesInTlabCount, totals.allocSamplesOutsideTlabCount),
                        totals.executionSampleCount,
                        average(totals.cpuMachineTotals),
                        percentile(totals.cpuMachineTotals, 95),
                        max(totals.cpuMachineTotals),
                        expDir.toString()
                ));
                writer.newLine();
            }
        }

        System.out.println("Wrote analysis CSVs to " + analysisDir);
    }

    // JFR을 읽어 대상 이벤트만 JSONL로 내보낸다
    static void writeSingleRunCsv(Path latencyCsv, Path runDir, Path jsonDir) throws IOException {
        try (BufferedWriter writer = Files.newBufferedWriter(latencyCsv)) {
            writer.write("topic,topic_count,producer_e2e_ms,produce_completion_ms,e2e_completion_remainder_ms,wait_on_metadata_ms,run_dir");
            writer.newLine();
            writeSingleRunRows(writer, runDir, jsonDir);
        }
    }

    static void writeSingleRunRows(BufferedWriter writer, Path runDir, Path jsonDir) throws IOException {
        Path jfrPath = findSingleJfr(runDir);
        if (jfrPath == null) {
            throw new IllegalStateException("JFR not found under " + runDir);
        }

        Path jsonPath = jsonDir.resolve(baseName(jfrPath.getFileName().toString()) + "-events.jsonl");
        writeEventsJson(jfrPath, jsonPath);

        Map<String, String> metrics = readMetricsFromRunDir(runDir);
        List<Double> e2eByTopic = extractSendAckMetrics(metrics);
        int topicCount = e2eByTopic.size();
        if (topicCount == 0) {
            throw new IllegalStateException("send_ack_ms_* not found in metrics under " + runDir);
        }

        List<TopicTotals> totals = new ArrayList<>();
        for (int i = 0; i < topicCount; i++) {
            totals.add(new TopicTotals());
        }

        EventTotals totalsAll = parseEventsJson(jsonPath);
        writeSummaryCsv(runDir, totalsAll);
        List<JsonLine> events = readJsonEvents(jsonPath);
        List<JsonLine> waitEvents = new ArrayList<>();
        List<JsonLine> parkEvents = new ArrayList<>();
        for (JsonLine event : events) {
            if ("jdk.JavaMonitorWait".equals(event.type)) {
                if (event.stack.contains(WAIT_ON_METADATA_METHOD)) {
                    waitEvents.add(event);
                }
            } else if ("jdk.ThreadPark".equals(event.type)) {
                if (stackContainsClass(event.stack, FUTURE_RECORD_METADATA_CLASS)
                        && isMainThread(event.threadName)) {
                    parkEvents.add(event);
                }
            }
        }

        waitEvents.sort(Comparator.comparingLong(e -> e.startNanos));
        parkEvents.sort(Comparator.comparingLong(e -> e.startNanos));

        Map<String, Integer> notifierTopicMap = new HashMap<>();
        int nextTopic = 1;
        for (JsonLine event : waitEvents) {
            int topicIndex = parseProducerId(event.notifierThread);
            if (topicIndex <= 0 || topicIndex > topicCount) {
                String key = event.notifierThread != null ? event.notifierThread : event.threadName;
                if (key != null && !key.isEmpty()) {
                    Integer mapped = notifierTopicMap.get(key);
                    if (mapped == null && nextTopic <= topicCount) {
                        mapped = nextTopic++;
                        notifierTopicMap.put(key, mapped);
                    }
                    if (mapped != null) {
                        topicIndex = mapped;
                    }
                }
            }
            if (topicIndex >= 1 && topicIndex <= topicCount) {
                totals.get(topicIndex - 1).waitOnMetadataNanos += event.durationNanos;
            }
        }

        for (int i = 0; i < parkEvents.size() && i < topicCount; i++) {
            totals.get(i).produceCompletionNanos += parkEvents.get(i).durationNanos;
        }

        for (int i = 0; i < topicCount; i++) {
            String topic = "test_topic_" + i;
            TopicTotals total = totals.get(i);
            double e2eMs = e2eByTopic.get(i);
            double produceCompletionMs = nanosToMs(total.produceCompletionNanos);
            double e2eMinusCompletionMs = e2eMs - produceCompletionMs;
            writer.write(String.format(
                    Locale.ROOT,
                    "%s,%d,%.3f,%.3f,%.3f,%.3f,%s",
                    topic,
                    i + 1,
                    e2eMs,
                    produceCompletionMs,
                    e2eMinusCompletionMs,
                    nanosToMs(total.waitOnMetadataNanos),
                    runDir.toString()
            ));
            writer.newLine();
        }
    }

    static void writeSummaryCsv(Path runDir, EventTotals totals) throws IOException {
        Path summaryPath = runDir.resolve("analysis").resolve("summary.csv");
        try (BufferedWriter writer = Files.newBufferedWriter(summaryPath)) {
            writer.write("run_dir,");
            writer.write("socket_read_sender_ms,socket_read_sender_count,");
            writer.write("socket_write_sender_ms,socket_write_sender_count,");
            writer.write("gc_pause_ms,safepoint_wait_ms,");
            writer.write("admin_client_monitor_block_ms,producer_monitor_block_ms,");
            writer.write("alloc_samples_in_tlab_count,alloc_samples_outside_tlab_count,outside_tlab_ratio,");
            writer.write("sender_cpu_samples,cpu_machine_avg,cpu_machine_p95,cpu_machine_max");
            writer.newLine();
            writer.write(String.format(
                    Locale.ROOT,
                    "%s,%.3f,%d,%.3f,%d,%.3f,%.3f,%.3f,%.3f,%d,%d,%.6f,%d,%.6f,%.6f,%.6f",
                    runDir.toString(),
                    nanosToMs(totals.socketReadNanos),
                    totals.socketReadCount,
                    nanosToMs(totals.socketWriteNanos),
                    totals.socketWriteCount,
                    nanosToMs(totals.gcPauseNanos),
                    nanosToMs(totals.safepointWaitNanos),
                    nanosToMs(totals.adminClientMonitorBlockNanos),
                    nanosToMs(totals.producerMonitorBlockNanos),
                    totals.allocSamplesInTlabCount,
                    totals.allocSamplesOutsideTlabCount,
                    outsideTlabRatio(totals.allocSamplesInTlabCount, totals.allocSamplesOutsideTlabCount),
                    totals.executionSampleCount,
                    average(totals.cpuMachineTotals),
                    percentile(totals.cpuMachineTotals, 95),
                    max(totals.cpuMachineTotals)
            ));
            writer.newLine();
        }
    }

    static void writeEventsJson(Path jfr, Path outJson) throws IOException {
        try (BufferedWriter writer = Files.newBufferedWriter(outJson);
             RecordingFile rf = new RecordingFile(jfr)) {
            while (rf.hasMoreEvents()) {
                RecordedEvent e = rf.readEvent();
                String en = e.getEventType().getName();
                if (!TARGET_EVENTS.contains(en)) {
                    continue;
                }

                long nanos = 0L;
                if (!"jdk.ExecutionSample".equals(en) && !"jdk.CPULoad".equals(en)) {
                    Duration d;
                    try {
                        d = e.getDuration();
                        nanos = d != null ? d.toNanos() : 0L;
                    } catch (Exception ex) {
                        nanos = 0L;
                    }
                }
                Double machineTotal = null;
                String threadName = null;
                String notifierThread = null;
                long startNanos = safeGetStartNanos(e);
                long endNanos = startNanos > 0L ? startNanos + nanos : 0L;
                if ("jdk.CPULoad".equals(en)) {
                    machineTotal = safeGetDouble(e, "machineTotal");
                }
                threadName = safeGetThreadName(e, "eventThread");
                if ("jdk.JavaMonitorWait".equals(en)) {
                    notifierThread = safeGetThreadName(e, "notifier");
                }

                List<String> stack = new ArrayList<>();
                RecordedStackTrace st = e.getStackTrace();
                if (st != null) {
                    List<RecordedFrame> frames = st.getFrames();
                    if (frames != null) {
                        for (RecordedFrame f : frames) {
                            String cls = f.getMethod().getType().getName();
                            String m = f.getMethod().getName();
                            stack.add(cls + "#" + m);
                        }
                    }
                }
                writeJsonEvent(writer, en, nanos, stack, machineTotal, threadName, startNanos, endNanos, notifierThread);
            }
        }
    }

    // JSONL 이벤트를 읽어 지연/카운터를 합산한다
    static EventTotals parseEventsJson(Path jsonPath) throws IOException {
        EventTotals totals = new EventTotals();
        try (BufferedReader reader = Files.newBufferedReader(jsonPath)) {
            String line;
            while ((line = reader.readLine()) != null) {
                JsonLine parsed = parseJsonLine(line.trim());
                if (parsed == null) {
                    continue;
                }

                String type = parsed.type;
                long nanos = parsed.durationNanos;
                if ("jdk.JavaMonitorWait".equals(type)) {
                    if (parsed.stack.contains(WAIT_ON_METADATA_METHOD)) {
                        totals.waitOnMetadataNanos += nanos;
                    }
                } else if ("jdk.ThreadPark".equals(type)) {
                    if (stackContainsClass(parsed.stack, FUTURE_RECORD_METADATA_CLASS)
                            && isMainThread(parsed.threadName)) {
                        totals.produceCompletionNanos += nanos;
                    }
                } else if ("jdk.SocketRead".equals(type)) {
                    totals.socketReadNanos += nanos;
                    totals.socketReadCount++;
                } else if ("jdk.SocketWrite".equals(type)) {
                    totals.socketWriteNanos += nanos;
                    totals.socketWriteCount++;
                } else if ("jdk.ExecutionSample".equals(type)) {
                    totals.executionSampleCount++;
                } else if ("jdk.ObjectAllocationInNewTLAB".equals(type)) {
                    totals.allocSamplesInTlabCount++;
                } else if ("jdk.ObjectAllocationOutsideTLAB".equals(type)) {
                    totals.allocSamplesOutsideTlabCount++;
                } else if ("jdk.CPULoad".equals(type)) {
                    if (parsed.machineTotal >= 0.0) {
                        totals.cpuMachineTotals.add(parsed.machineTotal);
                    }
                } else if ("jdk.GCPhasePause".equals(type)) {
                    totals.gcPauseNanos += nanos;
                } else if ("jdk.SafePointWait".equals(type)) {
                    totals.safepointWaitNanos += nanos;
                } else if ("jdk.JavaMonitorEnter".equals(type)) {
                    if (stackContainsClassPrefix(parsed.stack, "org.apache.kafka.clients.admin.KafkaAdminClient")) {
                        if (isMainThread(parsed.threadName)) {
                            totals.adminClientMonitorBlockNanos += nanos;
                        }
                    } else {
                        totals.producerMonitorBlockNanos += nanos;
                    }
                }
            }
        }
        return totals;
    }

    // 스택에 특정 클래스가 포함되는지 확인한다
    static List<JsonLine> readJsonEvents(Path jsonPath) throws IOException {
        List<JsonLine> events = new ArrayList<>();
        try (BufferedReader reader = Files.newBufferedReader(jsonPath)) {
            String line;
            while ((line = reader.readLine()) != null) {
                JsonLine parsed = parseJsonLine(line.trim());
                if (parsed != null) {
                    events.add(parsed);
                }
            }
        }
        return events;
    }

    static boolean stackContainsClass(List<String> stack, String className) {
        for (String frame : stack) {
            int idx = frame.indexOf('#');
            String cls = idx >= 0 ? frame.substring(0, idx) : frame;
            if (className.equals(cls)) {
                return true;
            }
        }
        return false;
    }

    // 스택에 특정 클래스 접두사가 포함되는지 확인한다
    static boolean stackContainsClassPrefix(List<String> stack, String classPrefix) {
        for (String frame : stack) {
            int idx = frame.indexOf('#');
            String cls = idx >= 0 ? frame.substring(0, idx) : frame;
            if (cls.startsWith(classPrefix)) {
                return true;
            }
        }
        return false;
    }

    // 나노초를 밀리초로 변환한다
    static double nanosToMs(long nanos) {
        return nanos / 1_000_000.0;
    }

    // 이벤트 한 건을 JSONL로 기록한다
    static void writeJsonEvent(BufferedWriter writer, String type, long nanos, List<String> stack,
                               Double machineTotal, String threadName, long startNanos, long endNanos,
                               String notifierThread)
            throws IOException {
        writer.write("{\"type\":\"");
        writer.write(escapeJson(type));
        writer.write("\",\"duration_nanos\":");
        writer.write(Long.toString(nanos));
        if (startNanos > 0L) {
            writer.write(",\"start_nanos\":");
            writer.write(Long.toString(startNanos));
        }
        if (endNanos > 0L) {
            writer.write(",\"end_nanos\":");
            writer.write(Long.toString(endNanos));
        }
        if (machineTotal != null) {
            writer.write(",\"machine_total\":");
            writer.write(Double.toString(machineTotal));
        }
        if (threadName != null && !threadName.isEmpty()) {
            writer.write(",\"thread\":\"");
            writer.write(escapeJson(threadName));
            writer.write("\"");
        }
        if (notifierThread != null && !notifierThread.isEmpty()) {
            writer.write(",\"notifier_thread\":\"");
            writer.write(escapeJson(notifierThread));
            writer.write("\"");
        }
        writer.write(",\"stack\":[");
        for (int i = 0; i < stack.size(); i++) {
            if (i > 0) {
                writer.write(",");
            }
            writer.write("\"");
            writer.write(escapeJson(stack.get(i)));
            writer.write("\"");
        }
        writer.write("]}");
        writer.newLine();
    }

    // JSON 문자열용 이스케이프 처리
    static String escapeJson(String value) {
        StringBuilder sb = new StringBuilder(value.length() + 8);
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c == '\\' || c == '"') {
                sb.append('\\').append(c);
            } else if (c == '\n') {
                sb.append("\\n");
            } else if (c == '\r') {
                sb.append("\\r");
            } else if (c == '\t') {
                sb.append("\\t");
            } else {
                sb.append(c);
            }
        }
        return sb.toString();
    }

    // JSONL 한 줄을 파싱한 결과
    static class JsonLine {
        final String type;
        final long durationNanos;
        final List<String> stack;
        final double machineTotal;
        final String threadName;
        final long startNanos;
        final long endNanos;
        final String notifierThread;

        JsonLine(String type, long durationNanos, List<String> stack, double machineTotal,
                 String threadName, long startNanos, long endNanos, String notifierThread) {
            this.type = type;
            this.durationNanos = durationNanos;
            this.stack = stack;
            this.machineTotal = machineTotal;
            this.threadName = threadName;
            this.startNanos = startNanos;
            this.endNanos = endNanos;
            this.notifierThread = notifierThread;
        }
    }

    // JSONL 한 줄에서 필요한 필드만 뽑는다
    static JsonLine parseJsonLine(String line) {
        if (line.isEmpty()) {
            return null;
        }
        String type = extractJsonString(line, "\"type\":\"");
        if (type == null) {
            return null;
        }
        long nanos = extractJsonLong(line, "\"duration_nanos\":");
        double machineTotal = extractJsonDouble(line, "\"machine_total\":");
        String threadName = extractJsonString(line, "\"thread\":\"");
        long startNanos = extractJsonLong(line, "\"start_nanos\":");
        long endNanos = extractJsonLong(line, "\"end_nanos\":");
        String notifierThread = extractJsonString(line, "\"notifier_thread\":\"");
        List<String> stack = extractJsonStringArray(line, "\"stack\":[");
        return new JsonLine(type, nanos, stack, machineTotal, threadName, startNanos, endNanos, notifierThread);
    }

    // 지정 키의 문자열 값을 추출한다
    static String extractJsonString(String line, String key) {
        int start = line.indexOf(key);
        if (start < 0) return null;
        start += key.length();
        StringBuilder sb = new StringBuilder();
        boolean escape = false;
        for (int i = start; i < line.length(); i++) {
            char c = line.charAt(i);
            if (escape) {
                sb.append(c);
                escape = false;
            } else if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                return sb.toString();
            } else {
                sb.append(c);
            }
        }
        return null;
    }

    // 지정 키의 long 값을 추출한다
    static long extractJsonLong(String line, String key) {
        int start = line.indexOf(key);
        if (start < 0) return 0L;
        start += key.length();
        int end = start;
        while (end < line.length() && Character.isDigit(line.charAt(end))) {
            end++;
        }
        if (end == start) return 0L;
        try {
            return Long.parseLong(line.substring(start, end));
        } catch (NumberFormatException ex) {
            return 0L;
        }
    }

    // 지정 키의 double 값을 추출한다
    static double extractJsonDouble(String line, String key) {
        int start = line.indexOf(key);
        if (start < 0) return -1.0;
        start += key.length();
        int end = start;
        while (end < line.length()) {
            char c = line.charAt(end);
            if (Character.isDigit(c) || c == '.' || c == '-' || c == 'e' || c == 'E' || c == '+') {
                end++;
            } else {
                break;
            }
        }
        if (end == start) return -1.0;
        try {
            return Double.parseDouble(line.substring(start, end));
        } catch (NumberFormatException ex) {
            return -1.0;
        }
    }

    // 평균을 계산한다
    static double average(List<Double> values) {
        if (values.isEmpty()) return 0.0;
        double sum = 0.0;
        for (double v : values) {
            sum += v;
        }
        return sum / values.size();
    }

    // 퍼센타일 값을 계산한다
    static double percentile(List<Double> values, int percentile) {
        if (values.isEmpty()) return 0.0;
        List<Double> sorted = new ArrayList<>(values);
        Collections.sort(sorted);
        double rank = percentile / 100.0 * sorted.size();
        int idx = (int) Math.ceil(rank) - 1;
        if (idx < 0) idx = 0;
        if (idx >= sorted.size()) idx = sorted.size() - 1;
        return sorted.get(idx);
    }

    // 최대값을 계산한다
    static double max(List<Double> values) {
        if (values.isEmpty()) return 0.0;
        double max = Double.NEGATIVE_INFINITY;
        for (double v : values) {
            if (v > max) {
                max = v;
            }
        }
        return max;
    }

    // TLAB 밖 할당 비율을 계산한다
    static double outsideTlabRatio(int inTlab, int outsideTlab) {
        int total = inTlab + outsideTlab;
        if (total <= 0) {
            return 0.0;
        }
        return (double) outsideTlab / total;
    }

    // JFR 필드에서 double을 안전하게 읽는다
    static double safeGetDouble(RecordedEvent e, String field) {
        try {
            return e.getDouble(field);
        } catch (Exception ex) {
            return -1.0;
        }
    }

    // JFR 스레드 이름을 안전하게 읽는다
    static String safeGetThreadName(RecordedEvent e, String field) {
        try {
            return e.getThread(field).getJavaName();
        } catch (Exception ex) {
            return null;
        }
    }

    // 메인 스레드 여부를 판정한다
    static boolean isMainThread(String threadName) {
        return "main".equals(threadName);
    }

    // JSON 배열(문자열 리스트)을 추출한다
    static List<String> extractJsonStringArray(String line, String key) {
        int start = line.indexOf(key);
        if (start < 0) return Collections.emptyList();
        start += key.length();
        int end = line.indexOf(']', start);
        if (end < 0) return Collections.emptyList();
        String body = line.substring(start, end).trim();
        if (body.isEmpty()) return Collections.emptyList();
        List<String> items = new ArrayList<>();
        StringBuilder sb = new StringBuilder();
        boolean inString = false;
        boolean escape = false;
        for (int i = 0; i < body.length(); i++) {
            char c = body.charAt(i);
            if (!inString) {
                if (c == '"') {
                    inString = true;
                }
                continue;
            }
            if (escape) {
                sb.append(c);
                escape = false;
            } else if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                items.add(sb.toString());
                sb.setLength(0);
                inString = false;
            } else {
                sb.append(c);
            }
        }
        return items;
    }

    // 확장자를 제거한 파일명을 만든다
    static String baseName(String name) {
        int dot = name.lastIndexOf('.');
        return dot > 0 ? name.substring(0, dot) : name;
    }

    // 실행 결과 디렉터리(YYYY... 형식)를 찾아 반환한다
    static Path findRunDir(Path base) throws IOException {
        if (Files.isDirectory(base)) {
            String name = base.getFileName().toString();
            if (name.startsWith("202") || name.startsWith("run")) {
                return base;
            }
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

    // 실험 디렉터리 목록을 찾고 정렬한다
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

    // 실험 디렉터리에서 JFR 파일을 찾는다
    static Path findJfr(Path expDir) throws IOException {
        Path candidate = findFirstMatching(expDir, "producer-", ".jfr");
        if (candidate != null) {
            return candidate;
        }
        return findFirstMatching(expDir, "", ".jfr");
    }

    // prefix/suffix에 맞는 첫 파일을 찾는다
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

    // metrics 파일을 읽어 key/value로 파싱한다
    static Map<String, String> readMetrics(Path expDir) throws IOException {
        Path metricsPath = findFirstMatching(expDir, "metrics-", ".txt");
        if (metricsPath == null) {
            metricsPath = expDir.resolve("metrics.txt");
            if (!Files.exists(metricsPath)) {
                return Collections.emptyMap();
            }
        }
        return readMetricsFile(metricsPath);
    }

    static Map<String, String> readMetricsFromRunDir(Path runDir) throws IOException {
        Path metricsPath = findFirstMatchingRecursive(runDir, "metrics", ".txt");
        if (metricsPath == null) {
            return Collections.emptyMap();
        }
        return readMetricsFile(metricsPath);
    }

    static Map<String, String> readMetricsFile(Path metricsPath) throws IOException {
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

    // 실험 디렉터리 이름에서 숫자 ID를 파싱한다
    static int parseExperimentId(String name) {
        int idx = name.lastIndexOf('-');
        if (idx < 0 || idx + 1 >= name.length()) return 0;
        try {
            return Integer.parseInt(name.substring(idx + 1));
        } catch (NumberFormatException ex) {
            return 0;
        }
    }

    // 토픽 이름에서 숫자 접미사를 뽑아 토픽 수로 사용한다
    static int inferTopicCount(String topic, int fallback) {
        Pattern pattern = Pattern.compile("(\\d+)$");
        Matcher matcher = pattern.matcher(topic);
        if (matcher.find()) {
            return Integer.parseInt(matcher.group(1));
        }
        return fallback;
    }

    static int parseProducerId(String threadName) {
        if (threadName == null) {
            return -1;
        }
        Matcher matcher = PRODUCER_ID_PATTERN.matcher(threadName);
        if (matcher.find()) {
            try {
                return Integer.parseInt(matcher.group(1));
            } catch (NumberFormatException ex) {
                return -1;
            }
        }
        return -1;
    }

    static List<Double> extractSendAckMetrics(Map<String, String> metrics) {
        Map<Integer, Double> indexed = new HashMap<>();
        for (Map.Entry<String, String> entry : metrics.entrySet()) {
            String key = entry.getKey();
            if (!key.startsWith("send_ack_ms_")) {
                continue;
            }
            String suffix = key.substring("send_ack_ms_".length());
            try {
                int idx = Integer.parseInt(suffix);
                double value = parseDoublePrefix(entry.getValue());
                indexed.put(idx, value);
            } catch (NumberFormatException ex) {
                // skip
            }
        }
        if (indexed.isEmpty()) {
            return Collections.emptyList();
        }
        int max = Collections.max(indexed.keySet());
        List<Double> values = new ArrayList<>();
        for (int i = 1; i <= max; i++) {
            values.add(indexed.getOrDefault(i, 0.0));
        }
        return values;
    }

    static Path findFirstMatchingRecursive(Path base, String prefix, String suffix) throws IOException {
        List<Path> matches = new ArrayList<>();
        try (Stream<Path> stream = Files.walk(base, 4)) {
            stream.filter(Files::isRegularFile)
                    .filter(p -> {
                        String name = p.getFileName().toString();
                        return name.startsWith(prefix) && name.endsWith(suffix);
                    })
                    .forEach(matches::add);
        }
        matches.sort(Comparator.naturalOrder());
        return matches.isEmpty() ? null : matches.get(0);
    }

    static Path findSingleJfr(Path runDir) throws IOException {
        List<Path> matches = new ArrayList<>();
        try (Stream<Path> stream = Files.walk(runDir, 4)) {
            stream.filter(Files::isRegularFile)
                    .filter(p -> p.getFileName().toString().endsWith(".jfr"))
                    .forEach(matches::add);
        }
        if (matches.isEmpty()) {
            return null;
        }
        matches.sort(Comparator.comparingLong(JfrLatencyBreakdown::lastModified));
        return matches.get(matches.size() - 1);
    }

    static long lastModified(Path path) {
        try {
            return Files.getLastModifiedTime(path).toMillis();
        } catch (IOException ex) {
            return 0L;
        }
    }

    static long safeGetStartNanos(RecordedEvent e) {
        try {
            Instant t = e.getStartTime();
            return (t.getEpochSecond() * 1_000_000_000L) + t.getNano();
        } catch (Exception ex) {
            return 0L;
        }
    }

    static double parseDoublePrefix(String raw) {
        if (raw == null) {
            return 0.0;
        }
        int end = 0;
        while (end < raw.length()) {
            char c = raw.charAt(end);
            if (Character.isDigit(c) || c == '.' || c == '-' || c == '+') {
                end++;
            } else {
                break;
            }
        }
        if (end == 0) {
            return 0.0;
        }
        return Double.parseDouble(raw.substring(0, end));
    }
}
