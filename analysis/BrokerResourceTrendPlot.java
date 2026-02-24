import javax.imageio.ImageIO;
import java.awt.*;
import java.awt.image.BufferedImage;
import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

public class BrokerResourceTrendPlot {
    private static final DateTimeFormatter TS_FMT = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");

    static class Row {
        final long epochMs;
        final double elapsedSec;
        final Double cpuPct;
        final Double rssMb;
        final Double heapUsedMb;
        final Double storageMb;

        Row(long epochMs, double elapsedSec, Double cpuPct, Double rssMb, Double heapUsedMb, Double storageMb) {
            this.epochMs = epochMs;
            this.elapsedSec = elapsedSec;
            this.cpuPct = cpuPct;
            this.rssMb = rssMb;
            this.heapUsedMb = heapUsedMb;
            this.storageMb = storageMb;
        }
    }

    static class RunSummary {
        String runTs;
        int sampleCount;
        double durationSec;
        Double cpuAvg;
        Double cpuMax;
        Double rssAvg;
        Double rssMax;
        Double heapAvg;
        Double heapMax;
        Double storageStart;
        Double storageEnd;
        Double storageDelta;
    }

    public static void main(String[] args) throws Exception {
        Path inputDir = null;
        Path outputDir = null;
        Path summaryCsv = null;

        for (int i = 0; i < args.length; i++) {
            String arg = args[i];
            if ("--input-dir".equals(arg) && i + 1 < args.length) {
                inputDir = Paths.get(args[++i]);
            } else if ("--output-dir".equals(arg) && i + 1 < args.length) {
                outputDir = Paths.get(args[++i]);
            } else if ("--summary-csv".equals(arg) && i + 1 < args.length) {
                summaryCsv = Paths.get(args[++i]);
            } else {
                throw new IllegalArgumentException("Unknown or invalid argument: " + arg);
            }
        }

        if (inputDir == null || outputDir == null || summaryCsv == null) {
            throw new IllegalArgumentException("Usage: java BrokerResourceTrendPlot --input-dir <dir> --output-dir <dir> --summary-csv <file>");
        }
        if (!Files.isDirectory(inputDir)) {
            throw new IllegalStateException("Input dir not found: " + inputDir);
        }

        Files.createDirectories(outputDir);
        if (summaryCsv.getParent() != null) {
            Files.createDirectories(summaryCsv.getParent());
        }

        List<Path> files = new ArrayList<>();
        try (DirectoryStream<Path> ds = Files.newDirectoryStream(inputDir, "*_broker_resource.csv")) {
            for (Path p : ds) {
                if (Files.isRegularFile(p)) files.add(p);
            }
        }
        files.sort(Comparator.naturalOrder());
        if (files.isEmpty()) {
            throw new IllegalStateException("No *_broker_resource.csv found in: " + inputDir);
        }

        List<RunSummary> summaries = new ArrayList<>();
        int written = 0;
        for (Path csv : files) {
            String fileName = csv.getFileName().toString();
            String runTs = fileName.replace("_broker_resource.csv", "");
            List<Row> rows = readRows(csv);
            if (rows.isEmpty()) continue;

            Path outPng = outputDir.resolve(runTs + "_resource_trends.png");
            drawRunPlot(runTs, rows, outPng);
            summaries.add(computeSummary(runTs, rows));
            written++;
        }

        if (written == 0) {
            throw new IllegalStateException("No valid resource rows found.");
        }
        writeSummaryCsv(summaryCsv, summaries);

        System.out.println("Wrote " + written + " resource trend plot(s) to " + outputDir);
        System.out.println("Wrote resource summary CSV: " + summaryCsv);
    }

    private static List<Row> readRows(Path csvPath) throws IOException {
        List<Long> epochs = new ArrayList<>();
        List<Double> cpu = new ArrayList<>();
        List<Double> rss = new ArrayList<>();
        List<Double> heap = new ArrayList<>();
        List<Double> storage = new ArrayList<>();

        try (BufferedReader r = Files.newBufferedReader(csvPath, StandardCharsets.UTF_8)) {
            String header = r.readLine();
            if (header == null) return List.of();
            String[] h = header.split(",", -1);

            int epochIdx = indexOf(h, "epoch_ms");
            int tsIdx = indexOf(h, "timestamp");
            int cpuIdx = indexOf(h, "cpu_pct");
            int rssIdx = indexOf(h, "rss_kb");
            int heapIdx = indexOf(h, "heap_used_kb");
            int storageIdx = indexOf(h, "storage_kb");

            String line;
            while ((line = r.readLine()) != null) {
                if (line.isBlank()) continue;
                String[] p = line.split(",", -1);

                Long epoch = parseEpochMs(safeGet(p, epochIdx));
                if (epoch == null) {
                    LocalDateTime ts = parseTimestamp(safeGet(p, tsIdx));
                    if (ts != null) {
                        epoch = ts.atZone(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli();
                    }
                }
                if (epoch == null) continue;

                epochs.add(epoch);
                cpu.add(parseNullableDouble(safeGet(p, cpuIdx)));
                rss.add(kbToMb(parseNullableDouble(safeGet(p, rssIdx))));
                heap.add(kbToMb(parseNullableDouble(safeGet(p, heapIdx))));
                storage.add(kbToMb(parseNullableDouble(safeGet(p, storageIdx))));
            }
        }

        if (epochs.isEmpty()) return List.of();

        long base = epochs.get(0);
        List<Row> out = new ArrayList<>(epochs.size());
        for (int i = 0; i < epochs.size(); i++) {
            long e = epochs.get(i);
            double elapsed = (e - base) / 1000.0;
            out.add(new Row(e, elapsed, cpu.get(i), rss.get(i), heap.get(i), storage.get(i)));
        }
        return out;
    }

    private static void drawRunPlot(String runTs, List<Row> rows, Path outPng) throws IOException {
        int width = 1300;
        int height = 960;
        BufferedImage img = new BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = img.createGraphics();
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
        g.setColor(Color.WHITE);
        g.fillRect(0, 0, width, height);

        g.setColor(new Color(20, 24, 35));
        g.setFont(new Font("SansSerif", Font.BOLD, 22));
        g.drawString("Broker Resource Trends - " + runTs, 24, 36);

        int panelX = 80;
        int panelW = width - 130;
        int panelH = 230;

        drawPanel(g, rows, panelX, 70, panelW, panelH,
            "CPU (%)", List.of(series(rows, "cpu", new Color(31, 119, 180))));

        drawPanel(g, rows, panelX, 350, panelW, panelH,
            "Memory (MB)", List.of(
                series(rows, "rss", new Color(44, 160, 44)),
                series(rows, "heap", new Color(255, 127, 14))
            ));

        drawPanel(g, rows, panelX, 630, panelW, panelH,
            "Disk (MB)", List.of(series(rows, "storage", new Color(214, 39, 40))));

        g.setFont(new Font("SansSerif", Font.PLAIN, 13));
        g.setColor(new Color(70, 75, 85));
        g.drawString("Elapsed Time (s)", width / 2 - 45, height - 20);

        g.dispose();
        ImageIO.write(img, "png", outPng.toFile());
    }

    static class Series {
        final String name;
        final Color color;
        final List<Double> values;

        Series(String name, Color color, List<Double> values) {
            this.name = name;
            this.color = color;
            this.values = values;
        }
    }

    private static Series series(List<Row> rows, String metric, Color color) {
        List<Double> vals = new ArrayList<>(rows.size());
        for (Row r : rows) {
            switch (metric) {
                case "cpu" -> vals.add(r.cpuPct);
                case "rss" -> vals.add(r.rssMb);
                case "heap" -> vals.add(r.heapUsedMb);
                case "storage" -> vals.add(r.storageMb);
                default -> vals.add(null);
            }
        }
        return new Series(metric, color, vals);
    }

    private static void drawPanel(Graphics2D g, List<Row> rows, int x, int y, int w, int h, String yLabel, List<Series> seriesList) {
        int left = x;
        int top = y;
        int right = x + w;
        int bottom = y + h;

        g.setColor(new Color(248, 250, 253));
        g.fillRect(left, top, w, h);

        g.setColor(new Color(218, 224, 235));
        g.drawRect(left, top, w, h);

        double minX = 0;
        double maxX = rows.get(rows.size() - 1).elapsedSec;
        if (maxX <= minX) maxX = minX + 1;

        Double minYObj = null;
        Double maxYObj = null;
        for (Series s : seriesList) {
            for (Double v : s.values) {
                if (v == null) continue;
                if (minYObj == null || v < minYObj) minYObj = v;
                if (maxYObj == null || v > maxYObj) maxYObj = v;
            }
        }
        if (minYObj == null || maxYObj == null) {
            minYObj = 0.0;
            maxYObj = 1.0;
        }
        double minY = minYObj;
        double maxY = maxYObj;
        if (Math.abs(maxY - minY) < 1e-9) {
            maxY = minY + 1;
        }
        double pad = (maxY - minY) * 0.08;
        minY -= pad;
        maxY += pad;

        g.setFont(new Font("SansSerif", Font.PLAIN, 12));
        g.setColor(new Color(200, 206, 218));
        for (int i = 0; i <= 5; i++) {
            int gy = top + (int) Math.round(h * (i / 5.0));
            g.drawLine(left, gy, right, gy);
        }

        for (Series s : seriesList) {
            g.setColor(s.color);
            int prevX = -1;
            int prevY = -1;
            for (int i = 0; i < rows.size(); i++) {
                Double v = s.values.get(i);
                if (v == null) continue;
                double xn = (rows.get(i).elapsedSec - minX) / (maxX - minX);
                double yn = (v - minY) / (maxY - minY);
                int px = left + (int) Math.round(xn * w);
                int py = bottom - (int) Math.round(yn * h);
                if (prevX >= 0) {
                    g.drawLine(prevX, prevY, px, py);
                }
                prevX = px;
                prevY = py;
            }
        }

        g.setColor(new Color(50, 57, 72));
        g.drawRect(left, top, w, h);
        g.setFont(new Font("SansSerif", Font.BOLD, 13));
        g.drawString(yLabel, left + 8, top + 18);

        g.setFont(new Font("SansSerif", Font.PLAIN, 11));
        String minYText = String.format("min %.2f", minYObj);
        String maxYText = String.format("max %.2f", maxYObj);
        g.drawString(maxYText, left + 8, top + 34);
        g.drawString(minYText, left + 8, bottom - 8);

        String maxXText = String.format("%.1fs", maxX);
        g.drawString("0s", left + 4, bottom + 16);
        int tw = g.getFontMetrics().stringWidth(maxXText);
        g.drawString(maxXText, right - tw - 4, bottom + 16);
    }

    private static RunSummary computeSummary(String runTs, List<Row> rows) {
        RunSummary s = new RunSummary();
        s.runTs = runTs;
        s.sampleCount = rows.size();
        s.durationSec = rows.get(rows.size() - 1).elapsedSec - rows.get(0).elapsedSec;

        s.cpuAvg = avg(rows, "cpu");
        s.cpuMax = max(rows, "cpu");
        s.rssAvg = avg(rows, "rss");
        s.rssMax = max(rows, "rss");
        s.heapAvg = avg(rows, "heap");
        s.heapMax = max(rows, "heap");

        List<Double> storage = collect(rows, "storage");
        if (!storage.isEmpty()) {
            s.storageStart = storage.get(0);
            s.storageEnd = storage.get(storage.size() - 1);
            s.storageDelta = s.storageEnd - s.storageStart;
        }
        return s;
    }

    private static void writeSummaryCsv(Path csv, List<RunSummary> rows) throws IOException {
        try (BufferedWriter w = Files.newBufferedWriter(csv, StandardCharsets.UTF_8)) {
            w.write("run_ts,sample_count,duration_sec,cpu_avg_pct,cpu_max_pct,rss_avg_mb,rss_max_mb,heap_used_avg_mb,heap_used_max_mb,storage_start_mb,storage_end_mb,storage_delta_mb\n");
            for (RunSummary s : rows) {
                w.write(String.join(",",
                    s.runTs,
                    String.valueOf(s.sampleCount),
                    fmt(s.durationSec),
                    fmt(s.cpuAvg),
                    fmt(s.cpuMax),
                    fmt(s.rssAvg),
                    fmt(s.rssMax),
                    fmt(s.heapAvg),
                    fmt(s.heapMax),
                    fmt(s.storageStart),
                    fmt(s.storageEnd),
                    fmt(s.storageDelta)
                ));
                w.write("\n");
            }
        }
    }

    private static String fmt(Double v) {
        if (v == null) return "";
        return String.format("%.3f", v);
    }

    private static List<Double> collect(List<Row> rows, String metric) {
        List<Double> vals = new ArrayList<>();
        for (Row r : rows) {
            Double v;
            switch (metric) {
                case "cpu" -> v = r.cpuPct;
                case "rss" -> v = r.rssMb;
                case "heap" -> v = r.heapUsedMb;
                case "storage" -> v = r.storageMb;
                default -> v = null;
            }
            if (v != null) vals.add(v);
        }
        return vals;
    }

    private static Double avg(List<Row> rows, String metric) {
        List<Double> vals = collect(rows, metric);
        if (vals.isEmpty()) return null;
        double s = 0;
        for (Double v : vals) s += v;
        return s / vals.size();
    }

    private static Double max(List<Row> rows, String metric) {
        List<Double> vals = collect(rows, metric);
        if (vals.isEmpty()) return null;
        double m = vals.get(0);
        for (Double v : vals) if (v > m) m = v;
        return m;
    }

    private static int indexOf(String[] headers, String name) {
        for (int i = 0; i < headers.length; i++) {
            if (name.equals(headers[i].trim())) return i;
        }
        return -1;
    }

    private static String safeGet(String[] arr, int idx) {
        if (idx < 0 || idx >= arr.length) return "";
        return arr[idx].trim();
    }

    private static Long parseEpochMs(String raw) {
        if (raw == null || raw.isBlank()) return null;
        String digits = raw.replaceAll("[^0-9]", "");
        if (digits.isEmpty()) return null;
        try {
            return Long.parseLong(digits);
        } catch (NumberFormatException e) {
            return null;
        }
    }

    private static LocalDateTime parseTimestamp(String raw) {
        if (raw == null || raw.isBlank()) return null;
        try {
            return LocalDateTime.parse(raw, TS_FMT);
        } catch (Exception e) {
            return null;
        }
    }

    private static Double parseNullableDouble(String raw) {
        if (raw == null || raw.isBlank()) return null;
        try {
            return Double.parseDouble(raw);
        } catch (NumberFormatException e) {
            return null;
        }
    }

    private static Double kbToMb(Double kb) {
        if (kb == null) return null;
        return kb / 1024.0;
    }
}
