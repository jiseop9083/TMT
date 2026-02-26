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
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

import javax.imageio.ImageIO;

public class FirstProduceWithMessageLoadPlot {
    private enum PlotType { SCATTER, LINE }
    private static final String[] PALETTE = {
            "#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd",
            "#8c564b", "#e377c2", "#7f7f7f", "#bcbd22", "#17becf"
    };

    private static class Series {
        final String label;
        final List<Double> xs;
        final List<Double> ys;
        final Color color;
        final PlotType type;

        Series(String label, List<Double> xs, List<Double> ys, Color color, PlotType type) {
            this.label = label;
            this.xs = xs;
            this.ys = ys;
            this.color = color;
            this.type = type;
        }
    }

    private static class Panel {
        final String title;
        final String xLabel;
        final String yLabel;
        final List<Series> series;

        Panel(String title, String xLabel, String yLabel, List<Series> series) {
            this.title = title;
            this.xLabel = xLabel;
            this.yLabel = yLabel;
            this.series = series;
        }
    }

    public static void main(String[] args) throws Exception {
        System.setProperty("java.awt.headless", "true");

        String outDirArg = "kafka-4.2/output/first-produce-with-message-load";
        String figDirArg = "";
        String timestampArg = "";
        boolean all = false;
        Double scatterYMinOverride = null;
        Double scatterYMaxOverride = null;

        for (int i = 0; i < args.length; i++) {
            String arg = args[i];
            if ("--out-dir".equals(arg) && i + 1 < args.length) {
                outDirArg = args[++i];
            } else if ("--fig-dir".equals(arg) && i + 1 < args.length) {
                figDirArg = args[++i];
            } else if ("--timestamp".equals(arg) && i + 1 < args.length) {
                timestampArg = args[++i];
            } else if ("--all".equals(arg)) {
                all = true;
            } else if ("--scatter-y-min".equals(arg) && i + 1 < args.length) {
                scatterYMinOverride = Double.parseDouble(args[++i]);
            } else if ("--scatter-y-max".equals(arg) && i + 1 < args.length) {
                scatterYMaxOverride = Double.parseDouble(args[++i]);
            } else if ("--help".equals(arg) || "-h".equals(arg)) {
                System.out.println(
                        "Usage: java FirstProduceWithMessageLoadPlot [--out-dir <dir>]\n"
                        + "       [--fig-dir <dir>] [--timestamp <YYYYMMDD_HHMMSS>] [--all]\n"
                        + "       [--scatter-y-min <value>] [--scatter-y-max <value>]\n"
                        + "Default: merge all timestamps into one figure per metric group.");
                return;
            } else {
                throw new IllegalArgumentException("Unknown argument: " + arg);
            }
        }

        Path outDir = Paths.get(outDirArg).toAbsolutePath().normalize();
        if (!Files.isDirectory(outDir)) {
            throw new IllegalStateException("Output directory not found: " + outDir);
        }

        Path figDir = figDirArg.isEmpty()
                ? outDir.resolve("plots")
                : Paths.get(figDirArg).toAbsolutePath().normalize();
        Files.createDirectories(figDir);

        List<String> timestamps = pickTimestamps(outDir, timestampArg, all);
        Map<String, List<Map<String, Double>>> combinedRowsByTs = new LinkedHashMap<>();
        Map<String, List<Map<String, Double>>> yammerRowsByTs = new LinkedHashMap<>();
        for (String ts : timestamps) {
            Path combinedCsv = outDir.resolve("combined_metrics_" + ts + ".csv");
            Path yammerCsv = outDir.resolve("yammer_" + ts + ".csv");

            List<Map<String, Double>> combinedRows = readNumericRows(combinedCsv);
            combinedRows.sort(Comparator.comparingDouble(r -> get(r, "topic_num")));
            List<Map<String, Double>> yammerRows = readNumericRows(yammerCsv);
            yammerRows.sort(Comparator.comparingDouble(r -> get(r, "topic_dir_count")));

            combinedRowsByTs.put(ts, combinedRows);
            yammerRowsByTs.put(ts, yammerRows);
        }

        List<Path> combinedOutputs = drawCombinedFigures(
                combinedRowsByTs, timestamps, figDir, scatterYMinOverride, scatterYMaxOverride);
        List<Path> yammerOutputs = drawYammerFigures(yammerRowsByTs, timestamps, figDir);

        System.out.println("timestamps merged: " + String.join(", ", timestamps));
        for (Path p : combinedOutputs) {
            System.out.println("combined scatter: " + p);
        }
        for (Path p : yammerOutputs) {
            System.out.println("yammer lines   : " + p);
        }
    }

    private static List<String> pickTimestamps(Path outDir, String requested, boolean all) throws IOException {
        Set<String> combined = listTimestamps(outDir, "combined_metrics_");
        Set<String> yammer = listTimestamps(outDir, "yammer_");
        combined.retainAll(yammer);

        if (combined.isEmpty()) {
            throw new IllegalStateException("No matching combined_metrics_*.csv and yammer_*.csv found in " + outDir);
        }

        List<String> sorted = new ArrayList<>(combined);
        Collections.sort(sorted);

        if (!requested.isEmpty()) {
            if (!combined.contains(requested)) {
                throw new IllegalArgumentException("Timestamp not found: " + requested + " available=" + sorted);
            }
            return List.of(requested);
        }

        return sorted;
    }

    private static Set<String> listTimestamps(Path dir, String prefix) throws IOException {
        Set<String> ts = new HashSet<>();
        try (var stream = Files.list(dir)) {
            stream.filter(p -> Files.isRegularFile(p) && p.getFileName().toString().startsWith(prefix)
                            && p.getFileName().toString().endsWith(".csv"))
                    .forEach(p -> {
                        String n = p.getFileName().toString();
                        ts.add(n.substring(prefix.length(), n.length() - 4));
                    });
        }
        return ts;
    }

    private static List<Map<String, Double>> readNumericRows(Path csv) throws IOException {
        List<Map<String, Double>> rows = new ArrayList<>();
        try (BufferedReader br = Files.newBufferedReader(csv)) {
            String header = br.readLine();
            if (header == null) {
                return rows;
            }
            String[] cols = header.split(",", -1);
            String line;
            while ((line = br.readLine()) != null) {
                if (line.isBlank()) {
                    continue;
                }
                String[] parts = line.split(",", -1);
                Map<String, Double> row = new HashMap<>();
                for (int i = 0; i < cols.length && i < parts.length; i++) {
                    String key = cols[i].trim();
                    String v = parts[i].trim();
                    if (v.isEmpty() || "null".equalsIgnoreCase(v)) {
                        continue;
                    }
                    try {
                        row.put(key, Double.parseDouble(v));
                    } catch (NumberFormatException ignored) {
                    }
                }
                rows.add(row);
            }
        }
        return rows;
    }

    private static List<Path> drawCombinedFigures(Map<String, List<Map<String, Double>>> rowsByTs,
                                                  List<String> timestamps,
                                                  Path figDir,
                                                  Double scatterYMinOverride,
                                                  Double scatterYMaxOverride) throws IOException {
        List<Series> e2eSeries = new ArrayList<>();
        List<Series> queueSeries = new ArrayList<>();
        List<Series> brokerProcSeries = new ArrayList<>();
        List<Series> brokerMetaUpdateSeries = new ArrayList<>();
        List<Series> brokerTopicCreateSeries = new ArrayList<>();
        List<Series> brokerGapSeries = new ArrayList<>();

        for (int i = 0; i < timestamps.size(); i++) {
            String ts = timestamps.get(i);
            List<Map<String, Double>> rows = rowsByTs.get(ts);
            if (rows == null) {
                continue;
            }
            List<Double> x = col(rows, "topic_num");
            if (!hasAnyFinite(x)) {
                continue;
            }

            e2eSeries.add(new Series("e2e_ms (" + shortTs(ts) + ")", x, col(rows, "e2e_ms"),
                    colorFor("e2e_ms", i), PlotType.SCATTER));
            queueSeries.add(new Series("metadata_req_queue_wait_ms (" + shortTs(ts) + ")", x,
                    col(rows, "metadata_req_queue_wait_ms"), colorFor("metadata_req_queue_wait_ms", i), PlotType.SCATTER));
            queueSeries.add(new Series("produce_queue_wait_ms (" + shortTs(ts) + ")", x,
                    col(rows, "produce_queue_wait_ms"), colorFor("produce_queue_wait_ms", i), PlotType.SCATTER));
            brokerProcSeries.add(new Series("broker_proc_time_ms_last (" + shortTs(ts) + ")", x,
                    col(rows, "broker_proc_time_ms_last"), colorFor("broker_proc_time_ms_last", i), PlotType.SCATTER));
            brokerMetaUpdateSeries.add(new Series("broker_meta_update_ms (" + shortTs(ts) + ")", x,
                    col(rows, "broker_meta_update_ms"), colorFor("broker_meta_update_ms", i), PlotType.SCATTER));
            brokerTopicCreateSeries.add(new Series("broker_topic_create_proc_ms (" + shortTs(ts) + ")", x,
                    col(rows, "broker_topic_create_proc_ms"), colorFor("broker_topic_create_proc_ms", i), PlotType.SCATTER));
            brokerGapSeries.add(new Series("gap=create-meta (" + shortTs(ts) + ")", x,
                    diffCol(rows, "broker_topic_create_proc_ms", "broker_meta_update_ms"),
                    colorFor("broker_gap_ms", i), PlotType.SCATTER));
        }

        if (e2eSeries.isEmpty()) {
            throw new IllegalStateException("No numeric data for combined_metrics topic_num");
        }

        Panel p1 = new Panel("E2E Latency", "Topic Count", "e2e_ms", e2eSeries);
        Panel p2 = new Panel("Queue Wait Time", "Topic Count", "ms", queueSeries);
        Panel p3 = new Panel("Broker Process Time (Last)", "Topic Count", "broker_proc_time_ms_last", brokerProcSeries);
        Panel p4 = new Panel("Broker Meta Update", "Topic Count", "broker_meta_update_ms", brokerMetaUpdateSeries);
        Panel p5 = new Panel("Broker Topic Create", "Topic Count", "broker_topic_create_proc_ms", brokerTopicCreateSeries);
        Panel p6 = new Panel("Broker Gap (Create - Meta)", "Topic Count", "gap_ms", brokerGapSeries);

        double e2eMax = maxSeriesY(e2eSeries);
        double scatterYMin = scatterYMinOverride != null ? scatterYMinOverride : 0.0;
        double scatterYMax = scatterYMaxOverride != null ? scatterYMaxOverride : e2eMax;
        if (!Double.isFinite(scatterYMax) || scatterYMax <= scatterYMin) {
            scatterYMax = scatterYMin + 1.0;
        }

        Path out1 = figDir.resolve("e2e.png");
        Path out2 = figDir.resolve("queue_wait.png");
        Path out3 = figDir.resolve("broker_proc_last.png");
        Path out4 = figDir.resolve("broker_meta_update_latency.png");
        Path out5 = figDir.resolve("broker_topic_create_latency.png");
        Path out6 = figDir.resolve("broker_gap_ms.png");
        drawSinglePanelFigure(p1, out1, scatterYMin, scatterYMax);
        drawSinglePanelFigure(p2, out2, scatterYMin, scatterYMax);
        drawSinglePanelFigure(p3, out3, scatterYMin, scatterYMax);
        drawSinglePanelFigure(p4, out4, scatterYMin, scatterYMax);
        drawSinglePanelFigure(p5, out5, scatterYMin, scatterYMax);
        drawSinglePanelFigure(p6, out6, scatterYMin, scatterYMax);
        return List.of(out1, out2, out3, out4, out5, out6);
    }

    private static List<Path> drawYammerFigures(Map<String, List<Map<String, Double>>> rowsByTs,
                                                List<String> timestamps,
                                                Path figDir) throws IOException {
        Path resourceDir = figDir.resolve("resource");
        Files.createDirectories(resourceDir);
        List<Path> outputs = new ArrayList<>();

        for (int i = 0; i < timestamps.size(); i++) {
            String ts = timestamps.get(i);
            List<Map<String, Double>> rows = rowsByTs.get(ts);
            if (rows == null) {
                continue;
            }
            List<Double> x = col(rows, "topic_dir_count");
            if (!hasAnyFinite(x)) {
                continue;
            }

            Panel cpuPanel = new Panel(
                    "CPU Usage (" + ts + ")",
                    "Topic Count (topic_dir_count)",
                    "cpu_pct",
                    List.of(new Series("cpu_pct", x, col(rows, "cpu_pct"), colorFor("cpu_pct", i), PlotType.LINE)));

            Panel memoryPanel = new Panel(
                    "Memory (" + ts + ")",
                    "Topic Count (topic_dir_count)",
                    "KB",
                    List.of(
                            new Series("rss_kb", x, col(rows, "rss_kb"), colorFor("rss_kb", i), PlotType.LINE),
                            new Series("heap_used_kb", x, col(rows, "heap_used_kb"), colorFor("heap_used_kb", i), PlotType.LINE)
                    ));

            Panel diskPanel = new Panel(
                    "Disk Usage (" + ts + ")",
                    "Topic Count (topic_dir_count)",
                    "storage_kb",
                    List.of(new Series("storage_kb", x, col(rows, "storage_kb"), colorFor("storage_kb", i), PlotType.LINE)));

            Path cpuOut = resourceDir.resolve("cpu_" + ts + ".png");
            Path memoryOut = resourceDir.resolve("memory_" + ts + ".png");
            Path diskOut = resourceDir.resolve("disk_" + ts + ".png");
            drawSinglePanelFigure(cpuPanel, cpuOut, null, null);
            drawSinglePanelFigure(memoryPanel, memoryOut, null, null);
            drawSinglePanelFigure(diskPanel, diskOut, null, null);
            outputs.add(cpuOut);
            outputs.add(memoryOut);
            outputs.add(diskOut);
        }

        if (outputs.isEmpty()) {
            throw new IllegalStateException("No numeric data for yammer topic_dir_count");
        }
        return outputs;
    }

    private static void draw2x2Figure(List<Panel> panels, Path outPath, boolean blankLast) throws IOException {
        int width = 1300;
        int height = 900;
        int outerPad = 20;
        int gap = 20;
        int cellW = (width - outerPad * 2 - gap) / 2;
        int cellH = (height - outerPad * 2 - gap) / 2;

        BufferedImage img = new BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = img.createGraphics();
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);

        g.setColor(Color.WHITE);
        g.fillRect(0, 0, width, height);

        for (int i = 0; i < 4; i++) {
            int row = i / 2;
            int col = i % 2;
            int x = outerPad + col * (cellW + gap);
            int y = outerPad + row * (cellH + gap);
            if (blankLast && i == 3) {
                g.setColor(hex("#f9fafb"));
                g.fillRect(x, y, cellW, cellH);
                g.setColor(hex("#d1d5db"));
                g.drawRect(x, y, cellW, cellH);
                continue;
            }
            drawPanel(g, panels.get(i), x, y, cellW, cellH, null, null);
        }

        g.dispose();
        ImageIO.write(img, "png", outPath.toFile());
    }

    private static void drawSinglePanelFigure(Panel panel, Path outPath, Double forceYMin, Double forceYMax)
            throws IOException {
        int width = 1100;
        int height = 700;
        BufferedImage img = new BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = img.createGraphics();
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
        g.setColor(Color.WHITE);
        g.fillRect(0, 0, width, height);
        drawPanel(g, panel, 20, 20, width - 40, height - 40, forceYMin, forceYMax);
        g.dispose();
        ImageIO.write(img, "png", outPath.toFile());
    }

    private static void drawPanel(Graphics2D g, Panel panel, int x, int y, int w, int h,
                                  Double forceYMin, Double forceYMax) {
        g.setColor(hex("#ffffff"));
        g.fillRect(x, y, w, h);
        g.setColor(hex("#e5e7eb"));
        g.drawRect(x, y, w, h);

        int left = x + 70;
        int right = x + w - 20;
        int top = y + 45;
        int bottom = y + h - 55;
        int plotW = right - left;
        int plotH = bottom - top;

        if (plotW <= 0 || plotH <= 0 || panel.series.isEmpty()) {
            return;
        }

        double minX = Double.POSITIVE_INFINITY;
        double maxX = Double.NEGATIVE_INFINITY;
        double minY = Double.POSITIVE_INFINITY;
        double maxY = Double.NEGATIVE_INFINITY;

        for (Series s : panel.series) {
            int n = Math.min(s.xs.size(), s.ys.size());
            for (int i = 0; i < n; i++) {
                double xv = s.xs.get(i);
                double yv = s.ys.get(i);
                if (Double.isNaN(xv) || Double.isNaN(yv)) {
                    continue;
                }
                minX = Math.min(minX, xv);
                maxX = Math.max(maxX, xv);
                minY = Math.min(minY, yv);
                maxY = Math.max(maxY, yv);
            }
        }

        if (!Double.isFinite(minX) || !Double.isFinite(maxX)) {
            return;
        }
        if (!Double.isFinite(minY) || !Double.isFinite(maxY)) {
            minY = 0.0;
            maxY = 1.0;
        }

        if (maxX <= minX) {
            maxX = minX + 1.0;
        }
        if (maxY <= minY) {
            maxY = minY + 1.0;
        }

        if (forceYMin != null) {
            minY = forceYMin;
        }
        if (forceYMax != null) {
            maxY = forceYMax;
        }
        if (maxY <= minY) {
            maxY = minY + 1.0;
        }
        if (forceYMin == null && forceYMax == null) {
            double yPad = Math.max((maxY - minY) * 0.08, 1e-6);
            minY -= yPad;
            maxY += yPad;
        }

        g.setFont(new Font("SansSerif", Font.BOLD, 16));
        g.setColor(hex("#111827"));
        g.drawString(panel.title, x + 14, y + 26);

        g.setColor(hex("#f3f4f6"));
        for (int i = 0; i <= 5; i++) {
            int gy = top + (int) Math.round(plotH * (i / 5.0));
            g.drawLine(left, gy, right, gy);
        }

        g.setColor(hex("#111827"));
        g.setStroke(new BasicStroke(1.5f));
        g.drawLine(left, bottom, right, bottom);
        g.drawLine(left, top, left, bottom);

        g.setFont(new Font("SansSerif", Font.PLAIN, 11));
        for (int i = 0; i <= 5; i++) {
            double ratio = i / 5.0;
            double xv = minX + (maxX - minX) * ratio;
            int px = left + (int) Math.round(plotW * ratio);
            g.drawLine(px, bottom, px, bottom + 4);
            String label = formatTick(xv);
            int lw = g.getFontMetrics().stringWidth(label);
            g.drawString(label, px - lw / 2, bottom + 18);
        }

        for (int i = 0; i <= 5; i++) {
            double ratio = i / 5.0;
            double yv = maxY - (maxY - minY) * ratio;
            int py = top + (int) Math.round(plotH * ratio);
            g.drawLine(left - 4, py, left, py);
            String label = formatTick(yv);
            int lw = g.getFontMetrics().stringWidth(label);
            g.drawString(label, left - 8 - lw, py + 4);
        }

        g.setFont(new Font("SansSerif", Font.PLAIN, 12));
        int xw = g.getFontMetrics().stringWidth(panel.xLabel);
        g.drawString(panel.xLabel, left + (plotW - xw) / 2, y + h - 18);

        AffineTransform old = g.getTransform();
        g.rotate(-Math.PI / 2.0, x + 18, top + plotH / 2.0);
        g.drawString(panel.yLabel, x + 18, top + plotH / 2);
        g.setTransform(old);

        for (Series s : panel.series) {
            g.setColor(s.color);
            g.setStroke(new BasicStroke(1.8f));

            int n = Math.min(s.xs.size(), s.ys.size());
            int prevX = Integer.MIN_VALUE;
            int prevY = Integer.MIN_VALUE;
            for (int i = 0; i < n; i++) {
                double xv = s.xs.get(i);
                double yv = s.ys.get(i);
                if (Double.isNaN(xv) || Double.isNaN(yv)) {
                    continue;
                }
                int px = map(xv, minX, maxX, left, right);
                int py = map(yv, minY, maxY, bottom, top);

                if (s.type == PlotType.LINE) {
                    if (prevX != Integer.MIN_VALUE) {
                        g.drawLine(prevX, prevY, px, py);
                    }
                    g.fillOval(px - 3, py - 3, 6, 6);
                    prevX = px;
                    prevY = py;
                } else {
                    g.fillOval(px - 3, py - 3, 7, 7);
                }
            }
        }

        int lx = right - 220;
        int ly = top + 6;
        g.setFont(new Font("SansSerif", Font.PLAIN, 11));
        for (Series s : panel.series) {
            g.setColor(s.color);
            g.fillRect(lx, ly - 8, 12, 8);
            g.setColor(hex("#111827"));
            g.drawString(s.label, lx + 16, ly);
            ly += 15;
        }
    }

    private static int map(double v, double minV, double maxV, int minP, int maxP) {
        double ratio = (v - minV) / (maxV - minV);
        ratio = Math.max(0.0, Math.min(1.0, ratio));
        return minP + (int) Math.round((maxP - minP) * ratio);
    }

    private static List<Double> col(List<Map<String, Double>> rows, String key) {
        List<Double> out = new ArrayList<>();
        for (Map<String, Double> row : rows) {
            out.add(get(row, key));
        }
        return out;
    }

    private static List<Double> diffCol(List<Map<String, Double>> rows, String minuendKey, String subtrahendKey) {
        List<Double> out = new ArrayList<>();
        for (Map<String, Double> row : rows) {
            double a = get(row, minuendKey);
            double b = get(row, subtrahendKey);
            if (Double.isNaN(a) || Double.isNaN(b)) {
                out.add(Double.NaN);
            } else {
                out.add(a - b);
            }
        }
        return out;
    }

    private static double maxSeriesY(List<Series> series) {
        double max = Double.NEGATIVE_INFINITY;
        for (Series s : series) {
            for (double y : s.ys) {
                if (!Double.isNaN(y)) {
                    max = Math.max(max, y);
                }
            }
        }
        return max;
    }

    private static boolean hasAnyFinite(List<Double> values) {
        for (double v : values) {
            if (!Double.isNaN(v)) {
                return true;
            }
        }
        return false;
    }

    private static double get(Map<String, Double> row, String key) {
        return row.getOrDefault(key, Double.NaN);
    }

    private static void ensureHasData(List<Double> values, String label) {
        for (double v : values) {
            if (!Double.isNaN(v)) {
                return;
            }
        }
        throw new IllegalStateException("No numeric data for " + label);
    }

    private static String formatTick(double v) {
        double a = Math.abs(v);
        if (a >= 1000) {
            return String.format(Locale.ROOT, "%.0f", v);
        }
        if (a >= 100) {
            return String.format(Locale.ROOT, "%.1f", v);
        }
        if (a >= 10) {
            return String.format(Locale.ROOT, "%.2f", v);
        }
        return String.format(Locale.ROOT, "%.3f", v);
    }

    private static Color hex(String s) {
        return Color.decode(s);
    }

    private static String shortTs(String ts) {
        int i = ts.indexOf('_');
        if (i >= 0 && i + 1 < ts.length()) {
            return ts.substring(i + 1);
        }
        return ts;
    }

    private static Color colorFor(String metric, int tsIndex) {
        int base = Math.floorMod(metric.hashCode(), PALETTE.length);
        int idx = Math.floorMod(base + tsIndex * 3, PALETTE.length);
        return hex(PALETTE[idx]);
    }
}
