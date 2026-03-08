import java.awt.BasicStroke;
import java.awt.Color;
import java.awt.Font;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.geom.AffineTransform;
import java.awt.image.BufferedImage;
import java.io.BufferedReader;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

import javax.imageio.ImageIO;

public class CreateDeleteMetricsPlot {
    private static final DateTimeFormatter TS_FMT = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS");

    static class ResourcePoint {
        final double elapsedSec;
        final double cpuPercent;
        final double memoryMb;
        final double diskPercent;

        ResourcePoint(double elapsedSec, double cpuPercent, double memoryMb, double diskPercent) {
            this.elapsedSec = elapsedSec;
            this.cpuPercent = cpuPercent;
            this.memoryMb = memoryMb;
            this.diskPercent = diskPercent;
        }
    }

    static class E2ePoint {
        final double elapsedSec;
        final double latencyMs;
        final String phase;
        final double brokerMetadataUpdateMs;

        E2ePoint(double elapsedSec, double latencyMs, String phase, double brokerMetadataUpdateMs) {
            this.elapsedSec = elapsedSec;
            this.latencyMs = latencyMs;
            this.phase = phase;
            this.brokerMetadataUpdateMs = brokerMetadataUpdateMs;
        }
    }

    static class BrokerPoint {
        final double elapsedSec;
        final double brokerMetadataUpdateMs;
        final String phase;

        BrokerPoint(double elapsedSec, double brokerMetadataUpdateMs, String phase) {
            this.elapsedSec = elapsedSec;
            this.brokerMetadataUpdateMs = brokerMetadataUpdateMs;
            this.phase = phase;
        }
    }

    static class DeletePoint {
        final double elapsedSec;
        final double deleteLatencyMs;

        DeletePoint(double elapsedSec, double deleteLatencyMs) {
            this.elapsedSec = elapsedSec;
            this.deleteLatencyMs = deleteLatencyMs;
        }
    }

    static class PhaseRange {
        final double startSec;
        final double endSec;

        PhaseRange(double startSec, double endSec) {
            this.startSec = startSec;
            this.endSec = endSec;
        }
    }

    static class RunPhaseInfo {
        final List<PhaseRange> createDeleteRanges;
        final double durationSec;

        RunPhaseInfo(List<PhaseRange> createDeleteRanges, double durationSec) {
            this.createDeleteRanges = createDeleteRanges;
            this.durationSec = durationSec;
        }
    }

    public static void main(String[] args) throws Exception {
        System.setProperty("java.awt.headless", "true");

        String runDirArg = "kafka-4.2/output/create-delete";
        String plotDirArg = "";

        for (int i = 0; i < args.length; i++) {
            String arg = args[i];
            if ("--run-dir".equals(arg) && i + 1 < args.length) {
                runDirArg = args[++i];
            } else if ("--plot-dir".equals(arg) && i + 1 < args.length) {
                plotDirArg = args[++i];
            } else if ("--help".equals(arg)) {
                System.out.println("Usage: java CreateDeleteMetricsPlot [--run-dir <dir>] [--plot-dir <dir>]");
                return;
            } else {
                throw new IllegalArgumentException("Unknown argument: " + arg);
            }
        }

        Path inputDir = Paths.get(runDirArg);
        boolean inputIsSingleRun = Files.isDirectory(inputDir) && hasExpectedCsv(inputDir);
        List<Path> runDirs = resolveRunDirs(inputDir);
        if (runDirs.isEmpty()) {
            throw new IllegalStateException("No run directory found under: " + inputDir);
        }

        Path plotDir;
        if (!plotDirArg.isEmpty()) {
            plotDir = Paths.get(plotDirArg);
        } else if (inputIsSingleRun && runDirs.size() == 1) {
            plotDir = runDirs.get(0).resolve("plots");
        } else {
            plotDir = inputDir.resolve("plots");
        }
        Files.createDirectories(plotDir);

        List<ResourcePoint> resources = new ArrayList<>();
        List<E2ePoint> e2e = new ArrayList<>();
        List<BrokerPoint> broker = new ArrayList<>();
        List<DeletePoint> deletes = new ArrayList<>();
        List<PhaseRange> createDeleteRanges = new ArrayList<>();
        double elapsedOffset = 0.0;
        final double runGapSec = 5.0;

        for (Path runDir : runDirs) {
            Path resourceCsv = runDir.resolve("resource_usage.csv");
            Path e2eCsv = runDir.resolve("e2e_latency.csv");
            Path eventsCsv = runDir.resolve("events.csv");
            Path deleteCsv = runDir.resolve("topic_delete_requests.csv");

            List<ResourcePoint> runResources = readResource(resourceCsv);
            List<E2ePoint> runE2e = readE2e(e2eCsv);
            List<BrokerPoint> runBroker = brokerPointsFromE2e(runE2e);
            List<DeletePoint> runDeletes = readDelete(runDir.resolve("e2e_latency.csv"), deleteCsv);
            RunPhaseInfo runPhase = readRunPhaseInfo(eventsCsv);

            appendShiftedResources(resources, runResources, elapsedOffset);
            appendShiftedE2e(e2e, runE2e, elapsedOffset);
            appendShiftedBroker(broker, runBroker, elapsedOffset);
            appendShiftedDelete(deletes, runDeletes, elapsedOffset);
            appendShiftedPhaseRanges(createDeleteRanges, runPhase.createDeleteRanges, elapsedOffset);

            double runDuration = Math.max(
                    maxElapsedResource(runResources),
                    Math.max(maxElapsedE2e(runE2e),
                            Math.max(maxElapsedBroker(runBroker), Math.max(maxElapsedDelete(runDeletes), runPhase.durationSec))));
            elapsedOffset += runDuration + runGapSec;
        }

        double e2eMinX = minElapsedE2e(e2e);
        double e2eMaxX = maxElapsedE2e(e2e);
        renderResourcePanels(resources, plotDir.resolve("resource_usage.png"), e2eMinX, e2eMaxX);
        renderE2eScatter(e2e, createDeleteRanges, plotDir.resolve("e2e_latency_scatter.png"));
        renderBrokerScatter(broker, plotDir.resolve("broker_metadata_scatter.png"));
        renderDeleteScatter(deletes, plotDir.resolve("delete_latency_scatter.png"));

        System.out.println("Input dir: " + inputDir);
        System.out.println("Merged runs: " + runDirs.size());
        System.out.println("Wrote: " + plotDir.resolve("resource_usage.png"));
        System.out.println("Wrote: " + plotDir.resolve("e2e_latency_scatter.png"));
        System.out.println("Wrote: " + plotDir.resolve("broker_metadata_scatter.png"));
        System.out.println("Wrote: " + plotDir.resolve("delete_latency_scatter.png"));
    }

    static List<Path> resolveRunDirs(Path input) throws IOException {
        if (Files.isDirectory(input) && hasExpectedCsv(input)) {
            return List.of(input);
        }
        if (!Files.isDirectory(input)) {
            throw new IllegalStateException("Directory not found: " + input);
        }
        List<Path> candidates = new ArrayList<>();
        try (var stream = Files.list(input)) {
            stream.filter(Files::isDirectory)
                    .filter(CreateDeleteMetricsPlot::hasExpectedCsv)
                    .forEach(candidates::add);
        }
        if (candidates.isEmpty()) {
            throw new IllegalStateException("No run directory with expected csv files under: " + input);
        }
        candidates.sort(Comparator.comparing(Path::getFileName));
        return candidates;
    }

    static boolean hasExpectedCsv(Path dir) {
        return Files.exists(dir.resolve("resource_usage.csv"))
                && Files.exists(dir.resolve("e2e_latency.csv"))
                && Files.exists(dir.resolve("broker_metadata_update.csv"));
    }

    static List<ResourcePoint> readResource(Path csv) throws IOException {
        List<ResourcePoint> rows = new ArrayList<>();
        try (BufferedReader reader = Files.newBufferedReader(csv)) {
            String header = reader.readLine();
            if (header == null) {
                return rows;
            }
            Map<String, Integer> idx = headerIndex(header);
            String line;
            long baseTs = -1L;
            while ((line = reader.readLine()) != null) {
                if (line.trim().isEmpty()) {
                    continue;
                }
                String[] p = line.split(",", -1);
                if (!"ok".equalsIgnoreCase(value(p, idx, "status"))) {
                    continue;
                }

                long ts = parseTs(value(p, idx, "timestamp"));
                if (ts < 0) {
                    continue;
                }
                if (baseTs < 0) {
                    baseTs = ts;
                }
                double elapsedSec = (ts - baseTs) / 1000.0;

                double processRaw = parseDouble(value(p, idx, "process_cpu_load"));
                double systemRaw = parseDouble(value(p, idx, "system_cpu_load"));
                double totalMem = parseDouble(value(p, idx, "total_mem_bytes"));
                double freeMem = parseDouble(value(p, idx, "free_mem_bytes"));
                double diskPct = parsePercent(value(p, idx, "disk_use_percent"));

                double cpuPercent = normalizeCpu(processRaw, systemRaw);
                double memoryMb = normalizeMemoryMb(processRaw, totalMem, freeMem);
                rows.add(new ResourcePoint(elapsedSec, cpuPercent, memoryMb, diskPct));
            }
        }
        rows.sort(Comparator.comparingDouble(r -> r.elapsedSec));
        return rows;
    }

    static List<E2ePoint> readE2e(Path csv) throws IOException {
        List<E2ePoint> rows = new ArrayList<>();
        try (BufferedReader reader = Files.newBufferedReader(csv)) {
            String header = reader.readLine();
            if (header == null) {
                return rows;
            }
            Map<String, Integer> idx = headerIndex(header);
            String line;
            long baseTs = -1L;
            while ((line = reader.readLine()) != null) {
                if (line.trim().isEmpty()) {
                    continue;
                }
                String[] p = line.split(",", -1);
                if (!"ok".equalsIgnoreCase(value(p, idx, "status"))) {
                    continue;
                }
                long ts = parseTs(value(p, idx, "timestamp"));
                if (ts < 0) {
                    continue;
                }
                if (baseTs < 0) {
                    baseTs = ts;
                }
                double elapsedSec = (ts - baseTs) / 1000.0;
                double latency = parseDouble(value(p, idx, "e2e_latency_ms"));
                if (Double.isNaN(latency)) {
                    latency = parseDouble(value(p, idx, "latency_ms"));
                }
                String phase = value(p, idx, "phase");
                double brokerMetadataUpdateMs = parseDouble(value(p, idx, "broker_metadata_update_ms"));
                rows.add(new E2ePoint(elapsedSec, latency, phase, brokerMetadataUpdateMs));
            }
        }
        rows.sort(Comparator.comparingDouble(r -> r.elapsedSec));
        return rows;
    }

    static RunPhaseInfo readRunPhaseInfo(Path eventsCsv) throws IOException {
        List<PhaseRange> ranges = new ArrayList<>();
        if (!Files.exists(eventsCsv)) {
            return new RunPhaseInfo(ranges, 0.0);
        }

        try (BufferedReader reader = Files.newBufferedReader(eventsCsv)) {
            String header = reader.readLine();
            if (header == null) {
                return new RunPhaseInfo(ranges, 0.0);
            }
            Map<String, Integer> idx = headerIndex(header);
            String line;
            long baseTs = -1L;
            double lastElapsed = 0.0;
            boolean inCreateDelete = false;
            double start = 0.0;

            while ((line = reader.readLine()) != null) {
                if (line.trim().isEmpty()) {
                    continue;
                }
                String[] p = line.split(",", -1);
                long ts = parseTs(value(p, idx, "timestamp"));
                if (ts < 0) {
                    continue;
                }
                if (baseTs < 0) {
                    baseTs = ts;
                }
                double elapsed = (ts - baseTs) / 1000.0;
                lastElapsed = Math.max(lastElapsed, elapsed);
                String phase = value(p, idx, "phase");
                boolean isCreateDelete = "create_delete".equalsIgnoreCase(phase);

                if (!inCreateDelete && isCreateDelete) {
                    start = elapsed;
                    inCreateDelete = true;
                } else if (inCreateDelete && !isCreateDelete) {
                    ranges.add(new PhaseRange(start, Math.max(start, elapsed)));
                    inCreateDelete = false;
                }
            }

            if (inCreateDelete) {
                ranges.add(new PhaseRange(start, Math.max(start, lastElapsed)));
            }
            return new RunPhaseInfo(ranges, lastElapsed);
        }
    }

    static List<BrokerPoint> brokerPointsFromE2e(List<E2ePoint> e2eRows) {
        List<BrokerPoint> rows = new ArrayList<>();
        for (E2ePoint p : e2eRows) {
            if (!Double.isNaN(p.brokerMetadataUpdateMs)) {
                rows.add(new BrokerPoint(p.elapsedSec, p.brokerMetadataUpdateMs, p.phase));
            }
        }
        rows.sort(Comparator.comparingDouble(r -> r.elapsedSec));
        return rows;
    }

    static List<DeletePoint> readDelete(Path e2eCsv, Path deleteCsv) throws IOException {
        List<DeletePoint> rows = new ArrayList<>();
        if (!Files.exists(deleteCsv)) {
            return rows;
        }
        long baseTs = readBaseTs(e2eCsv);
        if (baseTs < 0) {
            baseTs = readBaseTs(deleteCsv);
        }
        if (baseTs < 0) {
            return rows;
        }
        try (BufferedReader reader = Files.newBufferedReader(deleteCsv)) {
            String header = reader.readLine();
            if (header == null) {
                return rows;
            }
            Map<String, Integer> idx = headerIndex(header);
            String line;
            while ((line = reader.readLine()) != null) {
                if (line.trim().isEmpty()) {
                    continue;
                }
                String[] p = line.split(",", -1);
                if (!"ok".equalsIgnoreCase(value(p, idx, "status"))) {
                    continue;
                }
                long ts = parseTs(value(p, idx, "timestamp"));
                if (ts < 0) {
                    continue;
                }
                double elapsedSec = (ts - baseTs) / 1000.0;
                double deleteLatencyMs = parseDouble(value(p, idx, "delete_latency_ms"));
                rows.add(new DeletePoint(elapsedSec, deleteLatencyMs));
            }
        }
        rows.sort(Comparator.comparingDouble(r -> r.elapsedSec));
        return rows;
    }

    static long readBaseTs(Path csv) throws IOException {
        if (!Files.exists(csv)) {
            return -1L;
        }
        try (BufferedReader reader = Files.newBufferedReader(csv)) {
            String header = reader.readLine();
            if (header == null) {
                return -1L;
            }
            Map<String, Integer> idx = headerIndex(header);
            String line;
            while ((line = reader.readLine()) != null) {
                if (line.trim().isEmpty()) {
                    continue;
                }
                String[] p = line.split(",", -1);
                long ts = parseTs(value(p, idx, "timestamp"));
                if (ts >= 0) {
                    return ts;
                }
            }
        }
        return -1L;
    }

    static Map<String, Integer> headerIndex(String headerLine) {
        Map<String, Integer> idx = new HashMap<>();
        String[] h = headerLine.split(",", -1);
        for (int i = 0; i < h.length; i++) {
            idx.put(h[i].trim(), i);
        }
        return idx;
    }

    static String value(String[] parts, Map<String, Integer> idx, String key) {
        Integer i = idx.get(key);
        if (i == null || i < 0 || i >= parts.length) {
            return "";
        }
        return parts[i].trim();
    }

    static double parseDouble(String s) {
        if (s == null || s.isBlank()) {
            return Double.NaN;
        }
        try {
            return Double.parseDouble(s);
        } catch (NumberFormatException ex) {
            return Double.NaN;
        }
    }

    static double parsePercent(String s) {
        if (s == null || s.isBlank()) {
            return Double.NaN;
        }
        String clean = s.endsWith("%") ? s.substring(0, s.length() - 1) : s;
        return parseDouble(clean);
    }

    static long parseTs(String ts) {
        if (ts == null || ts.isBlank()) {
            return -1L;
        }
        try {
            return LocalDateTime.parse(ts, TS_FMT)
                    .atZone(java.time.ZoneId.systemDefault())
                    .toInstant()
                    .toEpochMilli();
        } catch (Exception ex) {
            return -1L;
        }
    }

    static double normalizeCpu(double processRaw, double systemRaw) {
        if (!Double.isNaN(processRaw) && processRaw >= 0.0 && processRaw <= 1.0) {
            return processRaw * 100.0;
        }
        if (!Double.isNaN(systemRaw) && systemRaw >= 0.0 && systemRaw <= 1.0) {
            return systemRaw * 100.0;
        }
        if (!Double.isNaN(processRaw) && processRaw >= 0.0 && processRaw <= 100.0) {
            return processRaw;
        }
        if (!Double.isNaN(systemRaw) && systemRaw >= 0.0 && systemRaw <= 100.0) {
            return systemRaw;
        }
        return Double.NaN;
    }

    static double normalizeMemoryMb(double processRaw, double totalMem, double freeMem) {
        double mb = 1024.0 * 1024.0;
        if (!Double.isNaN(processRaw) && processRaw > 1024.0) {
            return processRaw / mb;
        }
        if (!Double.isNaN(totalMem) && !Double.isNaN(freeMem) && totalMem > 0.0) {
            double used = totalMem - freeMem;
            if (used >= 0.0) {
                return used / mb;
            }
        }
        if (!Double.isNaN(freeMem) && freeMem > 0.0) {
            return freeMem / mb;
        }
        return Double.NaN;
    }

    static void renderResourcePanels(List<ResourcePoint> rows, Path outPath, double fixedMinX, double fixedMaxX) throws IOException {
        int width = 1300;
        int height = 980;
        int left = 80;
        int right = 30;
        int top = 60;
        int panelGap = 20;
        int panelHeight = 260;
        int bottom = 60;
        int plotWidth = width - left - right;

        BufferedImage image = new BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = image.createGraphics();
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
        g.setColor(Color.decode("#F3F4F6"));
        g.fillRect(0, 0, width, height);

        g.setColor(Color.decode("#1F2937"));
        g.setFont(new Font("SansSerif", Font.BOLD, 26));
        g.drawString("Kafka Broker Resource Usage", left, 36);

        List<Double> xs = new ArrayList<>();
        List<Double> cpu = new ArrayList<>();
        List<Double> mem = new ArrayList<>();
        List<Double> disk = new ArrayList<>();
        for (ResourcePoint r : rows) {
            if (!Double.isNaN(r.elapsedSec)) {
                xs.add(r.elapsedSec);
                cpu.add(r.cpuPercent);
                mem.add(r.memoryMb);
                disk.add(r.diskPercent);
            }
        }

        int y1 = top;
        int y2 = y1 + panelHeight + panelGap;
        int y3 = y2 + panelHeight + panelGap;

        drawLinePanel(g, left, y1, plotWidth, panelHeight, xs, cpu,
                "CPU (%)", Color.decode("#DC2626"), true, true, null, null, fixedMinX, fixedMaxX);
        drawLinePanel(g, left, y2, plotWidth, panelHeight, xs, mem,
                "Memory (MB)", Color.decode("#2563EB"), true, false, null, null, fixedMinX, fixedMaxX);
        drawLinePanel(g, left, y3, plotWidth, panelHeight, xs, disk,
                "Disk (%)", Color.decode("#16A34A"), true, false, null, null, fixedMinX, fixedMaxX);

        g.setColor(Color.decode("#374151"));
        g.setFont(new Font("SansSerif", Font.PLAIN, 14));
        String xLabel = "Elapsed Time (sec)";
        int labelWidth = g.getFontMetrics().stringWidth(xLabel);
        g.drawString(xLabel, left + (plotWidth - labelWidth) / 2, height - 18);

        g.dispose();
        ImageIO.write(image, "png", outPath.toFile());
    }

    static void drawLinePanel(Graphics2D g, int x, int y, int w, int h,
                              List<Double> xs, List<Double> ys,
                              String yLabel, Color lineColor,
                              boolean showXLabels, boolean clampCpu,
                              Double fixedMinY, Double fixedMaxY) {
        drawLinePanel(g, x, y, w, h, xs, ys, yLabel, lineColor, showXLabels, clampCpu, fixedMinY, fixedMaxY, null, null);
    }

    static void drawLinePanel(Graphics2D g, int x, int y, int w, int h,
                              List<Double> xs, List<Double> ys,
                              String yLabel, Color lineColor,
                              boolean showXLabels, boolean clampCpu,
                              Double fixedMinY, Double fixedMaxY,
                              Double fixedMinX, Double fixedMaxX) {
        g.setColor(Color.decode("#E5E7EB"));
        g.fillRect(x, y, w, h);

        double minX = fixedMinX != null ? fixedMinX : finiteMin(xs);
        double maxX = fixedMaxX != null ? fixedMaxX : finiteMax(xs);
        if (maxX <= minX) {
            maxX = minX + 1.0;
        }

        double minY = fixedMinY != null ? fixedMinY : finiteMin(ys);
        double maxY = fixedMaxY != null ? fixedMaxY : finiteMax(ys);
        if (clampCpu) {
            minY = Math.max(0.0, minY);
            maxY = Math.min(100.0, Math.max(maxY, 10.0));
        }
        if (maxY <= minY) {
            maxY = minY + 1.0;
        }

        g.setColor(Color.decode("#D1D5DB"));
        g.setStroke(new BasicStroke(1f));
        for (int i = 0; i <= 5; i++) {
            int gy = y + (int) (h * (i / 5.0));
            g.drawLine(x, gy, x + w, gy);
        }

        g.setColor(Color.decode("#6B7280"));
        g.setStroke(new BasicStroke(1.2f));
        g.drawRect(x, y, w, h);

        int prevX = -1;
        int prevY = -1;
        g.setColor(lineColor);
        g.setStroke(new BasicStroke(2f));
        for (int i = 0; i < xs.size() && i < ys.size(); i++) {
            double xv = xs.get(i);
            double yv = ys.get(i);
            if (Double.isNaN(xv) || Double.isNaN(yv)) {
                prevX = -1;
                prevY = -1;
                continue;
            }
            int px = x + (int) ((xv - minX) / (maxX - minX) * w);
            int py = y + h - (int) ((yv - minY) / (maxY - minY) * h);
            if (prevX >= 0) {
                g.drawLine(prevX, prevY, px, py);
            }
            prevX = px;
            prevY = py;
        }

        g.setFont(new Font("SansSerif", Font.PLAIN, 12));
        g.setColor(Color.decode("#374151"));
        for (int i = 0; i <= 4; i++) {
            double ratio = i / 4.0;
            double yv = minY + (maxY - minY) * (1.0 - ratio);
            int py = y + (int) (h * ratio);
            String label = tick(yv);
            int lw = g.getFontMetrics().stringWidth(label);
            g.drawString(label, x - lw - 8, py + 4);
        }

        AffineTransform saved = g.getTransform();
        g.rotate(-Math.PI / 2.0);
        int labelWidth = g.getFontMetrics().stringWidth(yLabel);
        g.drawString(yLabel, -(y + (h + labelWidth) / 2), x - 50);
        g.setTransform(saved);

        if (showXLabels) {
            for (int i = 0; i <= 6; i++) {
                double ratio = i / 6.0;
                double xv = minX + (maxX - minX) * ratio;
                int px = x + (int) (w * ratio);
                String label = tick(xv);
                int lw = g.getFontMetrics().stringWidth(label);
                g.drawString(label, px - lw / 2, y + h + 18);
            }
        }
    }

    static void renderE2eScatter(List<E2ePoint> rows, List<PhaseRange> createDeleteRanges, Path outPath)
            throws IOException {
        List<Double> xs = new ArrayList<>();
        List<Double> ys = new ArrayList<>();
        for (E2ePoint r : rows) {
            if (!Double.isNaN(r.elapsedSec) && !Double.isNaN(r.latencyMs)) {
                xs.add(r.elapsedSec);
                ys.add(r.latencyMs);
            }
        }
        renderScatter(
                xs,
                List.of(ys),
                List.of("E2E latency (ms)"),
                List.of(Color.decode("#1D4ED8")),
                "E2E Latency Scatter",
                outPath,
                "Elapsed Time (sec)",
                "Latency (ms)",
                createDeleteRanges,
                0.0,
                200.0);
    }

    static void renderBrokerScatter(List<BrokerPoint> rows, Path outPath) throws IOException {
        List<Double> xs = new ArrayList<>();
        List<Double> ys = new ArrayList<>();
        for (BrokerPoint r : rows) {
            if (!Double.isNaN(r.elapsedSec) && !Double.isNaN(r.brokerMetadataUpdateMs)) {
                xs.add(r.elapsedSec);
                ys.add(r.brokerMetadataUpdateMs);
            }
        }
        renderScatter(
                xs,
                List.of(ys),
                List.of("topic events"),
                List.of(Color.decode("#DC2626")),
                "Broker Metadata Update By Topic",
                outPath,
                "Elapsed Time (sec)",
                "Update Time (ms)",
                List.of(),
                0.0,
                200.0);
    }

    static void renderDeleteScatter(List<DeletePoint> rows, Path outPath) throws IOException {
        List<Double> xs = new ArrayList<>();
        List<Double> ys = new ArrayList<>();
        for (DeletePoint r : rows) {
            if (!Double.isNaN(r.elapsedSec) && !Double.isNaN(r.deleteLatencyMs)) {
                xs.add(r.elapsedSec);
                ys.add(r.deleteLatencyMs);
            }
        }
        renderScatter(
                xs,
                List.of(ys),
                List.of("delete latency (ms)"),
                List.of(Color.decode("#0EA5E9")),
                "Delete Latency Scatter",
                outPath,
                "Elapsed Time (sec)",
                "Latency (ms)",
                List.of(),
                0.0,
                200.0);
    }

    static void appendShiftedResources(List<ResourcePoint> target, List<ResourcePoint> source, double offsetSec) {
        for (ResourcePoint p : source) {
            target.add(new ResourcePoint(p.elapsedSec + offsetSec, p.cpuPercent, p.memoryMb, p.diskPercent));
        }
    }

    static void appendShiftedE2e(List<E2ePoint> target, List<E2ePoint> source, double offsetSec) {
        for (E2ePoint p : source) {
            target.add(new E2ePoint(p.elapsedSec + offsetSec, p.latencyMs, p.phase, p.brokerMetadataUpdateMs));
        }
    }

    static void appendShiftedBroker(List<BrokerPoint> target, List<BrokerPoint> source, double offsetSec) {
        for (BrokerPoint p : source) {
            target.add(new BrokerPoint(
                    p.elapsedSec + offsetSec, p.brokerMetadataUpdateMs, p.phase));
        }
    }

    static void appendShiftedDelete(List<DeletePoint> target, List<DeletePoint> source, double offsetSec) {
        for (DeletePoint p : source) {
            target.add(new DeletePoint(p.elapsedSec + offsetSec, p.deleteLatencyMs));
        }
    }

    static void appendShiftedPhaseRanges(List<PhaseRange> target, List<PhaseRange> source, double offsetSec) {
        for (PhaseRange p : source) {
            target.add(new PhaseRange(p.startSec + offsetSec, p.endSec + offsetSec));
        }
    }

    static double maxElapsedResource(List<ResourcePoint> rows) {
        double max = 0.0;
        for (ResourcePoint r : rows) {
            if (!Double.isNaN(r.elapsedSec)) {
                max = Math.max(max, r.elapsedSec);
            }
        }
        return max;
    }

    static double maxElapsedE2e(List<E2ePoint> rows) {
        double max = 0.0;
        for (E2ePoint r : rows) {
            if (!Double.isNaN(r.elapsedSec)) {
                max = Math.max(max, r.elapsedSec);
            }
        }
        return max;
    }

    static double minElapsedE2e(List<E2ePoint> rows) {
        double min = Double.POSITIVE_INFINITY;
        for (E2ePoint r : rows) {
            if (!Double.isNaN(r.elapsedSec)) {
                min = Math.min(min, r.elapsedSec);
            }
        }
        return min == Double.POSITIVE_INFINITY ? 0.0 : min;
    }

    static double maxElapsedBroker(List<BrokerPoint> rows) {
        double max = 0.0;
        for (BrokerPoint r : rows) {
            if (!Double.isNaN(r.elapsedSec)) {
                max = Math.max(max, r.elapsedSec);
            }
        }
        return max;
    }

    static double maxElapsedDelete(List<DeletePoint> rows) {
        double max = 0.0;
        for (DeletePoint r : rows) {
            if (!Double.isNaN(r.elapsedSec)) {
                max = Math.max(max, r.elapsedSec);
            }
        }
        return max;
    }

    static void renderScatter(List<Double> xs,
                              List<List<Double>> series,
                              List<String> labels,
                              List<Color> colors,
                              String title,
                              Path outPath,
                              String xLabel,
                              String yLabel,
                              List<PhaseRange> highlightRanges,
                              Double fixedMinY,
                              Double fixedMaxY) throws IOException {
        int width = 1200;
        int height = 640;
        int left = 80;
        int right = 30;
        int top = 60;
        int bottom = 70;
        int plotW = width - left - right;
        int plotH = height - top - bottom;

        double minX = finiteMin(xs);
        double maxX = finiteMax(xs);
        if (maxX <= minX) {
            maxX = minX + 1.0;
        }
        double minY = fixedMinY != null ? fixedMinY : finiteMinSeries(series);
        double maxY = fixedMaxY != null ? fixedMaxY : finiteMaxSeries(series);
        if (maxY <= minY) {
            maxY = minY + 1.0;
        }

        BufferedImage image = new BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = image.createGraphics();
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
        g.setColor(Color.WHITE);
        g.fillRect(0, 0, width, height);

        if (highlightRanges != null && !highlightRanges.isEmpty()) {
            g.setColor(new Color(239, 68, 68, 45));
            for (PhaseRange range : highlightRanges) {
                double x1v = Math.max(minX, range.startSec);
                double x2v = Math.min(maxX, range.endSec);
                if (x2v <= x1v) {
                    continue;
                }
                int x1 = left + (int) ((x1v - minX) / (maxX - minX) * plotW);
                int x2 = left + (int) ((x2v - minX) / (maxX - minX) * plotW);
                g.fillRect(x1, top, Math.max(1, x2 - x1), plotH);
            }
        }

        g.setColor(Color.decode("#E5E7EB"));
        for (int i = 0; i <= 5; i++) {
            int gy = top + (int) (plotH * (i / 5.0));
            g.drawLine(left, gy, left + plotW, gy);
        }

        g.setColor(Color.decode("#111827"));
        g.setStroke(new BasicStroke(1.2f));
        g.drawRect(left, top, plotW, plotH);

        g.setFont(new Font("SansSerif", Font.BOLD, 24));
        g.drawString(title, left, 36);

        g.setFont(new Font("SansSerif", Font.PLAIN, 13));
        for (int i = 0; i <= 6; i++) {
            double ratio = i / 6.0;
            double xv = minX + (maxX - minX) * ratio;
            int px = left + (int) (plotW * ratio);
            String label = tick(xv);
            int lw = g.getFontMetrics().stringWidth(label);
            g.drawString(label, px - lw / 2, top + plotH + 20);
        }

        for (int i = 0; i <= 5; i++) {
            double ratio = i / 5.0;
            double yv = maxY - (maxY - minY) * ratio;
            int py = top + (int) (plotH * ratio);
            String label = tick(yv);
            int lw = g.getFontMetrics().stringWidth(label);
            g.drawString(label, left - lw - 8, py + 4);
        }

        g.setFont(new Font("SansSerif", Font.PLAIN, 14));
        int xw = g.getFontMetrics().stringWidth(xLabel);
        g.drawString(xLabel, left + (plotW - xw) / 2, height - 18);

        AffineTransform saved = g.getTransform();
        g.rotate(-Math.PI / 2.0);
        int yw = g.getFontMetrics().stringWidth(yLabel);
        g.drawString(yLabel, -(top + (plotH + yw) / 2), 24);
        g.setTransform(saved);

        for (int s = 0; s < series.size(); s++) {
            g.setColor(colors.get(s));
            List<Double> ys = series.get(s);
            for (int i = 0; i < xs.size() && i < ys.size(); i++) {
                double xv = xs.get(i);
                double yv = ys.get(i);
                if (Double.isNaN(xv) || Double.isNaN(yv)) {
                    continue;
                }
                int px = left + (int) ((xv - minX) / (maxX - minX) * plotW);
                int py = top + plotH - (int) ((yv - minY) / (maxY - minY) * plotH);
                g.fillOval(px - 2, py - 2, 4, 4);
            }
        }

        int legendX = left + 8;
        int legendY = top + 8;
        g.setFont(new Font("SansSerif", Font.PLAIN, 12));
        for (int i = 0; i < labels.size(); i++) {
            g.setColor(colors.get(i));
            g.fillRect(legendX, legendY + i * 18, 12, 12);
            g.setColor(Color.decode("#111827"));
            g.drawString(labels.get(i), legendX + 18, legendY + 11 + i * 18);
        }

        g.dispose();
        ImageIO.write(image, "png", outPath.toFile());
    }

    static double finiteMin(List<Double> values) {
        double min = Double.POSITIVE_INFINITY;
        for (double v : values) {
            if (!Double.isNaN(v)) {
                min = Math.min(min, v);
            }
        }
        return min == Double.POSITIVE_INFINITY ? 0.0 : min;
    }

    static double finiteMax(List<Double> values) {
        double max = Double.NEGATIVE_INFINITY;
        for (double v : values) {
            if (!Double.isNaN(v)) {
                max = Math.max(max, v);
            }
        }
        return max == Double.NEGATIVE_INFINITY ? 1.0 : max;
    }

    static double finiteMinSeries(List<List<Double>> series) {
        double min = Double.POSITIVE_INFINITY;
        for (List<Double> values : series) {
            min = Math.min(min, finiteMin(values));
        }
        return min == Double.POSITIVE_INFINITY ? 0.0 : min;
    }

    static double finiteMaxSeries(List<List<Double>> series) {
        double max = Double.NEGATIVE_INFINITY;
        for (List<Double> values : series) {
            max = Math.max(max, finiteMax(values));
        }
        return max == Double.NEGATIVE_INFINITY ? 1.0 : max;
    }

    static String tick(double value) {
        if (Math.abs(value) >= 1000.0) {
            return String.format(Locale.ROOT, "%.0f", value);
        }
        if (Math.abs(value) >= 100.0) {
            return String.format(Locale.ROOT, "%.1f", value);
        }
        if (Math.abs(value) >= 10.0) {
            return String.format(Locale.ROOT, "%.2f", value);
        }
        return String.format(Locale.ROOT, "%.3f", value);
    }
}
