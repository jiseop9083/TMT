import java.awt.BasicStroke;
import java.awt.Color;
import java.awt.Font;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.image.BufferedImage;
import java.io.BufferedReader;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.text.DecimalFormat;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import javax.imageio.ImageIO;

public class ProducerJfrImpactPlot {
    static class Point {
        final int topicNum;
        final double latencyMs;
        final String condition;
        final int iteration;

        Point(int topicNum, double latencyMs, String condition, int iteration) {
            this.topicNum = topicNum;
            this.latencyMs = latencyMs;
            this.condition = condition;
            this.iteration = iteration;
        }
    }

    static class PlotSeries {
        final String label;
        final Color color;
        final List<Point> points;

        PlotSeries(String label, Color color, List<Point> points) {
            this.label = label;
            this.color = color;
            this.points = points;
        }
    }

    static class NiceScale {
        final double min;
        final double max;
        final double tickSpacing;

        NiceScale(double min, double max, double tickSpacing) {
            this.min = min;
            this.max = max;
            this.tickSpacing = tickSpacing;
        }
    }

    static final Map<String, Color> COLOR_BY_CONDITION = new LinkedHashMap<>();
    static {
        COLOR_BY_CONDITION.put("off", new Color(47, 107, 255, 160));
        COLOR_BY_CONDITION.put("default", new Color(255, 122, 0, 160));
        COLOR_BY_CONDITION.put("profile", new Color(0, 163, 108, 160));
        COLOR_BY_CONDITION.put("custom", new Color(220, 38, 38, 160));
    }

    public static void main(String[] args) throws Exception {
        System.setProperty("java.awt.headless", "true");

        String runDirArg = "";
        String outDirArg = "";
        for (int i = 0; i < args.length; i++) {
            String arg = args[i];
            if ("--run-dir".equals(arg) && i + 1 < args.length) {
                runDirArg = args[++i];
            } else if ("--out-dir".equals(arg) && i + 1 < args.length) {
                outDirArg = args[++i];
            } else if ("--help".equals(arg) || "-h".equals(arg)) {
                System.out.println("Usage: java ProducerJfrImpactPlot --run-dir <dir> [--out-dir <dir>]");
                return;
            } else {
                throw new IllegalArgumentException("Unknown argument: " + arg);
            }
        }

        if (runDirArg.isEmpty()) {
            throw new IllegalArgumentException("--run-dir is required");
        }

        Path runDir = Paths.get(runDirArg);
        Path outDir = outDirArg.isEmpty() ? runDir.resolve("plots") : Paths.get(outDirArg);
        Files.createDirectories(outDir);

        List<PlotSeries> seriesList = new ArrayList<>();
        List<Point> all = new ArrayList<>();
        for (String condition : discoverConditions(runDir)) {
            List<Point> points = readCondition(runDir.resolve(condition), condition);
            if (points.isEmpty()) {
                continue;
            }
            all.addAll(points);
            seriesList.add(new PlotSeries(prettyCondition(condition), colorFor(condition), points));
        }

        if (seriesList.isEmpty()) {
            throw new IllegalStateException("No producer latency CSV files found under " + runDir);
        }

        NiceScale fullScale = computeNiceScale(all, 0.0, 1.08, 8);
        int maxTopic = maxTopic(all);

        renderScatterPlot(
                seriesList,
                outDir.resolve("producer_e2e_overlay_scatter.png"),
                "Producer E2E Latency: All Conditions",
                maxTopic,
                fullScale);

        for (PlotSeries series : seriesList) {
            String filename = "producer_e2e_" + series.label.toLowerCase().replace(' ', '_') + "_scatter.png";
            renderScatterPlot(
                    List.of(series),
                    outDir.resolve(filename),
                    "Producer E2E Latency: " + series.label,
                    maxTopic,
                    fullScale);
        }

        System.out.println("Wrote plots to " + outDir);
    }

    static List<String> discoverConditions(Path runDir) throws IOException {
        List<String> conditions = new ArrayList<>();
        try (var stream = Files.list(runDir)) {
            stream.filter(Files::isDirectory)
                    .map(p -> p.getFileName().toString())
                    .sorted(Comparator.comparingInt(ProducerJfrImpactPlot::conditionOrder).thenComparing(String::compareTo))
                    .forEach(conditions::add);
        }
        return conditions;
    }

    static int conditionOrder(String name) {
        return switch (name) {
            case "off" -> 0;
            case "default" -> 1;
            case "profile" -> 2;
            case "custom" -> 3;
            default -> 100;
        };
    }

    static String prettyCondition(String condition) {
        return switch (condition) {
            case "off" -> "Off";
            case "default" -> "Default";
            case "profile" -> "Profile";
            case "custom" -> "Custom";
            default -> condition;
        };
    }

    static Color colorFor(String condition) {
        Color color = COLOR_BY_CONDITION.get(condition);
        return color != null ? color : new Color(107, 114, 128, 160);
    }

    static List<Point> readCondition(Path conditionDir, String condition) throws IOException {
        List<Point> points = new ArrayList<>();
        if (!Files.isDirectory(conditionDir)) {
            return points;
        }
        List<Path> csvs = new ArrayList<>();
        try (var stream = Files.walk(conditionDir, 3)) {
            stream.filter(Files::isRegularFile)
                    .filter(p -> p.getFileName().toString().equals("producer_latency_results.csv"))
                    .forEach(csvs::add);
        }
        csvs.sort(Comparator.naturalOrder());
        for (Path csv : csvs) {
            int iteration = parseIteration(csv.getParent().getFileName().toString());
            points.addAll(readCsv(csv, condition, iteration));
        }
        points.sort(Comparator.comparingInt((Point p) -> p.topicNum).thenComparingInt(p -> p.iteration));
        return points;
    }

    static List<Point> readCsv(Path csv, String condition, int iteration) throws IOException {
        List<Point> points = new ArrayList<>();
        try (BufferedReader reader = Files.newBufferedReader(csv)) {
            String header = reader.readLine();
            if (header == null) {
                return points;
            }
            Map<String, Integer> idx = indexHeader(header);
            String line;
            while ((line = reader.readLine()) != null) {
                if (line.trim().isEmpty()) {
                    continue;
                }
                String[] parts = line.split(",", -1);
                String latencyRaw = value(parts, idx, "latency_ms");
                if (latencyRaw.isEmpty() || "ERROR".equalsIgnoreCase(latencyRaw)) {
                    continue;
                }
                int topicNum = parseInt(value(parts, idx, "topic_num"));
                double latencyMs = parseDouble(latencyRaw);
                points.add(new Point(topicNum, latencyMs, condition, iteration));
            }
        }
        return points;
    }

    static Map<String, Integer> indexHeader(String headerLine) {
        Map<String, Integer> idx = new HashMap<>();
        String[] headers = headerLine.split(",", -1);
        for (int i = 0; i < headers.length; i++) {
            idx.put(headers[i].trim(), i);
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

    static int parseIteration(String name) {
        if (!name.startsWith("iteration_")) {
            return 0;
        }
        return parseInt(name.substring("iteration_".length()));
    }

    static int parseInt(String raw) {
        try {
            return Integer.parseInt(raw.trim());
        } catch (Exception ex) {
            return 0;
        }
    }

    static double parseDouble(String raw) {
        try {
            return Double.parseDouble(raw.trim());
        } catch (Exception ex) {
            return 0.0;
        }
    }

    static int maxTopic(List<Point> points) {
        int max = 1;
        for (Point point : points) {
            max = Math.max(max, point.topicNum);
        }
        return max;
    }

    static NiceScale computeNiceScale(List<Point> points, double minFloor, double headroomFactor, int targetTicks) {
        double max = Double.NEGATIVE_INFINITY;
        for (Point point : points) {
            max = Math.max(max, point.latencyMs);
        }
        if (Double.isInfinite(max)) {
            return new NiceScale(0.0, 1.0, 0.2);
        }
        double paddedMax = Math.max(max * headroomFactor, max + 1.0);
        double range = niceNum(paddedMax - minFloor, false);
        double tick = niceNum(range / Math.max(targetTicks - 1, 1), true);
        double niceMax = Math.ceil(paddedMax / tick) * tick;
        if (niceMax <= minFloor) {
            niceMax = minFloor + tick;
        }
        return new NiceScale(minFloor, niceMax, tick);
    }

    static double niceNum(double range, boolean round) {
        if (range <= 0.0) {
            return 1.0;
        }
        double exponent = Math.floor(Math.log10(range));
        double fraction = range / Math.pow(10, exponent);
        double niceFraction;
        if (round) {
            if (fraction < 1.5) {
                niceFraction = 1.0;
            } else if (fraction < 3.0) {
                niceFraction = 2.0;
            } else if (fraction < 7.0) {
                niceFraction = 5.0;
            } else {
                niceFraction = 10.0;
            }
        } else {
            if (fraction <= 1.0) {
                niceFraction = 1.0;
            } else if (fraction <= 2.0) {
                niceFraction = 2.0;
            } else if (fraction <= 5.0) {
                niceFraction = 5.0;
            } else {
                niceFraction = 10.0;
            }
        }
        return niceFraction * Math.pow(10, exponent);
    }

    static void renderScatterPlot(List<PlotSeries> seriesList, Path outPath, String title, int maxTopic, NiceScale scale)
            throws IOException {
        int width = 1300;
        int height = 720;
        int left = 90;
        int right = 40;
        int top = 70;
        int bottom = 80;
        int plotWidth = width - left - right;
        int plotHeight = height - top - bottom;

        BufferedImage image = new BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = image.createGraphics();
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
        g.setColor(Color.WHITE);
        g.fillRect(0, 0, width, height);

        g.setColor(new Color(229, 231, 235));
        g.setStroke(new BasicStroke(1f));
        int yTickCount = (int) Math.round((scale.max - scale.min) / scale.tickSpacing);
        for (int i = 0; i <= yTickCount; i++) {
            double yValue = scale.min + scale.tickSpacing * i;
            double ratio = (yValue - scale.min) / (scale.max - scale.min);
            int y = top + plotHeight - (int) Math.round(plotHeight * ratio);
            g.drawLine(left, y, left + plotWidth, y);
        }

        int[] xTicks = buildTopicTicks(maxTopic);
        for (int xTick : xTicks) {
            double ratio = xTick / (double) maxTopic;
            int x = left + (int) Math.round(plotWidth * ratio);
            g.drawLine(x, top, x, top + plotHeight);
        }

        g.setColor(new Color(17, 24, 39));
        g.setStroke(new BasicStroke(2f));
        g.drawLine(left, top, left, top + plotHeight);
        g.drawLine(left, top + plotHeight, left + plotWidth, top + plotHeight);

        g.setFont(new Font("SansSerif", Font.BOLD, 22));
        g.drawString(title, left, 35);
        g.setFont(new Font("SansSerif", Font.PLAIN, 14));
        g.drawString("Topic number", left + plotWidth / 2 - 40, height - 24);
        g.drawString("Latency (ms)", 14, top + plotHeight / 2);

        drawTicks(g, left, top, plotWidth, plotHeight, maxTopic, scale, xTicks);
        drawLegend(g, width - right - 230, top - 18, seriesList);

        for (PlotSeries series : seriesList) {
            g.setColor(series.color);
            for (Point point : series.points) {
                int x = left + (int) Math.round((point.topicNum / (double) maxTopic) * plotWidth);
                int y = top + plotHeight - (int) Math.round(((point.latencyMs - scale.min) / (scale.max - scale.min)) * plotHeight);
                g.fillOval(x - 2, y - 2, 4, 4);
            }
        }

        g.dispose();
        ImageIO.write(image, "png", outPath.toFile());
    }

    static void drawTicks(Graphics2D g, int left, int top, int plotWidth, int plotHeight,
                          int maxTopic, NiceScale scale, int[] xTicks) {
        g.setFont(new Font("SansSerif", Font.PLAIN, 12));
        g.setColor(new Color(55, 65, 81));
        DecimalFormat df = new DecimalFormat("0.###");

        for (int xTick : xTicks) {
            double ratio = xTick / (double) maxTopic;
            int x = left + (int) Math.round(plotWidth * ratio);
            g.drawLine(x, top + plotHeight, x, top + plotHeight + 5);
            String label = Integer.toString(xTick);
            int w = g.getFontMetrics().stringWidth(label);
            g.drawString(label, x - w / 2, top + plotHeight + 22);
        }

        int yTickCount = (int) Math.round((scale.max - scale.min) / scale.tickSpacing);
        for (int i = 0; i <= yTickCount; i++) {
            double yValue = scale.min + scale.tickSpacing * i;
            double ratio = (yValue - scale.min) / (scale.max - scale.min);
            int y = top + plotHeight - (int) Math.round(plotHeight * ratio);
            g.drawLine(left - 5, y, left, y);
            String label = df.format(yValue);
            int w = g.getFontMetrics().stringWidth(label);
            g.drawString(label, left - 10 - w, y + 4);
        }
    }

    static void drawLegend(Graphics2D g, int x, int y, List<PlotSeries> seriesList) {
        g.setFont(new Font("SansSerif", Font.PLAIN, 13));
        int legendY = y;
        for (PlotSeries series : seriesList) {
            g.setColor(series.color);
            g.fillOval(x, legendY, 10, 10);
            g.setColor(new Color(17, 24, 39));
            g.drawString(series.label + " (" + series.points.size() + " points)", x + 18, legendY + 10);
            legendY += 20;
        }
    }

    static int[] buildTopicTicks(int maxTopic) {
        int tickCount = 6;
        int[] ticks = new int[tickCount + 1];
        for (int i = 0; i <= tickCount; i++) {
            ticks[i] = (int) Math.round((maxTopic * i) / (double) tickCount);
        }
        ticks[0] = 0;
        ticks[ticks.length - 1] = maxTopic;
        return ticks;
    }
}
