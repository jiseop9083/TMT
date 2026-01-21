import java.awt.BasicStroke;
import java.awt.Color;
import java.awt.Font;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.image.BufferedImage;
import java.io.BufferedReader;
import java.io.IOException;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import javax.imageio.ImageIO;

public class JfrLatencyPlot {
    static class Row {
        final double topicCount;
        final double producerE2eMs;
        final double produceCompletionMs;
        final double waitOnMetadataMs;

        Row(double topicCount, double producerE2eMs, double produceCompletionMs, double waitOnMetadataMs) {
            this.topicCount = topicCount;
            this.producerE2eMs = producerE2eMs;
            this.produceCompletionMs = produceCompletionMs;
            this.waitOnMetadataMs = waitOnMetadataMs;
        }
    }

    public static void main(String[] args) throws Exception {
        System.setProperty("java.awt.headless", "true");

        String outDirArg = "client_profile_job/out";
        String analysisDirArg = "";
        String plotDirArg = "";
        boolean useZscoreFilter = false;
        double zscoreThreshold = 3.0;

        for (int i = 0; i < args.length; i++) {
            String arg = args[i];
            if ("--out-dir".equals(arg) && i + 1 < args.length) {
                outDirArg = args[++i];
            } else if ("--analysis-dir".equals(arg) && i + 1 < args.length) {
                analysisDirArg = args[++i];
            } else if ("--plot-dir".equals(arg) && i + 1 < args.length) {
                plotDirArg = args[++i];
            } else if ("--zscore-filter".equals(arg)) {
                useZscoreFilter = true;
            } else if ("--zscore-threshold".equals(arg) && i + 1 < args.length) {
                zscoreThreshold = Double.parseDouble(args[++i]);
            } else if ("--help".equals(arg)) {
                System.out.println(
                        "Usage: java JfrLatencyPlot --out-dir <dir> [--analysis-dir <dir>] [--plot-dir <dir>]\n" +
                        "       [--zscore-filter] [--zscore-threshold <value>]");
                return;
            } else {
                throw new IllegalArgumentException("Unknown argument: " + arg);
            }
        }

        Path analysisDir = analysisDirArg.isEmpty()
                ? findRunDir(Paths.get(outDirArg)).resolve("analysis")
                : Paths.get(analysisDirArg);
        if (!Files.exists(analysisDir)) {
            throw new IllegalStateException("analysis dir not found: " + analysisDir);
        }

        Path plotDir = plotDirArg.isEmpty() ? analysisDir.resolve("plots") : Paths.get(plotDirArg);
        Files.createDirectories(plotDir);

        Path latencyCsv = analysisDir.resolve("latency_breakdown.csv");
        if (!Files.exists(latencyCsv)) {
            throw new IllegalStateException("latency_breakdown.csv not found: " + latencyCsv);
        }

        List<Row> rows = readLatencyRows(latencyCsv);
        if (useZscoreFilter) {
            rows = filterByZscore(rows, zscoreThreshold);
        }
        rows.sort(Comparator.comparingDouble(r -> r.topicCount));

        plotE2eLatency(rows, plotDir.resolve("e2e_latency.png"));
        plotDelayBreakdown(rows, plotDir.resolve("delay_breakdown.png"));

        System.out.println("Wrote plots to " + plotDir);
    }

    static List<Row> readLatencyRows(Path csvPath) throws IOException {
        List<Row> rows = new ArrayList<>();
        try (BufferedReader reader = Files.newBufferedReader(csvPath)) {
            String headerLine = reader.readLine();
            if (headerLine == null) {
                return rows;
            }
            String[] headers = headerLine.split(",");
            Map<String, Integer> idx = new HashMap<>();
            for (int i = 0; i < headers.length; i++) {
                idx.put(headers[i].trim(), i);
            }
            String line;
            while ((line = reader.readLine()) != null) {
                if (line.trim().isEmpty()) {
                    continue;
                }
                String[] parts = line.split(",", -1);
                double topicCount = parseDouble(parts, idx, "topic_count");
                double producerE2e = parseDouble(parts, idx, "producer_e2e_ms");
                double produceCompletion = parseDouble(parts, idx, "produce_completion_ms");
                double waitOnMetadata = parseDouble(parts, idx, "wait_on_metadata_ms");
                rows.add(new Row(topicCount, producerE2e, produceCompletion, waitOnMetadata));
            }
        }
        return rows;
    }

    static List<Row> filterByZscore(List<Row> rows, double threshold) {
        if (rows.isEmpty()) {
            return rows;
        }
        Stats e2e = stats(rows, Metric.E2E);
        Stats completion = stats(rows, Metric.PRODUCE_COMPLETION);
        Stats metadata = stats(rows, Metric.WAIT_ON_METADATA);

        List<Row> filtered = new ArrayList<>();
        for (Row row : rows) {
            if (isOutlier(row.producerE2eMs, e2e, threshold)) {
                continue;
            }
            if (isOutlier(row.produceCompletionMs, completion, threshold)) {
                continue;
            }
            if (isOutlier(row.waitOnMetadataMs, metadata, threshold)) {
                continue;
            }
            filtered.add(row);
        }
        return filtered;
    }

    enum Metric { E2E, PRODUCE_COMPLETION, WAIT_ON_METADATA }

    static Stats stats(List<Row> rows, Metric metric) {
        double sum = 0.0;
        double sumSq = 0.0;
        int n = 0;
        for (Row row : rows) {
            double v = switch (metric) {
                case E2E -> row.producerE2eMs;
                case PRODUCE_COMPLETION -> row.produceCompletionMs;
                case WAIT_ON_METADATA -> row.waitOnMetadataMs;
            };
            sum += v;
            sumSq += v * v;
            n++;
        }
        if (n <= 1) {
            return new Stats(sum, 0.0, n);
        }
        double mean = sum / n;
        double variance = Math.max(0.0, (sumSq / n) - (mean * mean));
        double stddev = Math.sqrt(variance);
        return new Stats(mean, stddev, n);
    }

    static boolean isOutlier(double value, Stats stats, double threshold) {
        if (stats.stddev <= 0.0) {
            return false;
        }
        double z = (value - stats.mean) / stats.stddev;
        return Math.abs(z) > threshold;
    }

    static class Stats {
        final double mean;
        final double stddev;
        final int count;

        Stats(double mean, double stddev, int count) {
            this.mean = mean;
            this.stddev = stddev;
            this.count = count;
        }
    }

    static double parseDouble(String[] parts, Map<String, Integer> idx, String key) {
        Integer i = idx.get(key);
        if (i == null || i < 0 || i >= parts.length) {
            return 0.0;
        }
        String value = parts[i].trim();
        if (value.isEmpty()) {
            return 0.0;
        }
        try {
            return Double.parseDouble(value);
        } catch (NumberFormatException ex) {
            return 0.0;
        }
    }

    static void plotE2eLatency(List<Row> rows, Path outPath) throws IOException {
        List<Double> xs = new ArrayList<>();
        List<Double> ys = new ArrayList<>();
        for (Row row : rows) {
            xs.add(row.topicCount);
            ys.add(row.producerE2eMs);
        }
        PlotSpec spec = new PlotSpec("E2E latency", "topic_count", "latency(ms)");
        renderScatterPlot(xs, ys, spec, outPath, Color.decode("#2F6BFF"));
    }

    static void plotDelayBreakdown(List<Row> rows, Path outPath) throws IOException {
        List<Double> xs = new ArrayList<>();
        List<Double> produceCompletion = new ArrayList<>();
        List<Double> waitOnMetadata = new ArrayList<>();
        for (Row row : rows) {
            xs.add(row.topicCount);
            produceCompletion.add(row.produceCompletionMs);
            waitOnMetadata.add(row.waitOnMetadataMs);
        }
        PlotSpec spec = new PlotSpec("Delay breakdown", "topic_count", "latency(ms)");
        renderMultiSeriesPlot(
                xs,
                List.of(produceCompletion, waitOnMetadata),
                List.of("messageSend", "waitOnMetadata"),
                List.of(Color.decode("#00A36C"), Color.decode("#FF7A00")),
                spec,
                outPath
        );
    }

    static class PlotSpec {
        final String title;
        final String xLabel;
        final String yLabel;

        PlotSpec(String title, String xLabel, String yLabel) {
            this.title = title;
            this.xLabel = xLabel;
            this.yLabel = yLabel;
        }
    }

    static void renderScatterPlot(List<Double> xs, List<Double> ys, PlotSpec spec,
                                  Path outPath, Color color) throws IOException {
        renderMultiSeriesPlot(xs, List.of(ys), List.of("E2E latency"),
                List.of(color), spec, outPath);
    }

    static void renderMultiSeriesPlot(List<Double> xs, List<List<Double>> series,
                                      List<String> labels, List<Color> colors,
                                      PlotSpec spec, Path outPath) throws IOException {
        int width = 900;
        int height = 520;
        int left = 70;
        int right = 30;
        int top = 50;
        int bottom = 60;
        int plotWidth = width - left - right;
        int plotHeight = height - top - bottom;

        double minX = min(xs);
        double maxX = max(xs);
        double minY = 0.0;
        double maxY = maxSeries(series);
        if (maxX <= minX) {
            maxX = minX + 1.0;
        }
        if (maxY <= minY) {
            maxY = minY + 1.0;
        }

        BufferedImage image = new BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = image.createGraphics();
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
        g.setColor(Color.WHITE);
        g.fillRect(0, 0, width, height);

        g.setColor(Color.decode("#E5E7EB"));
        g.setStroke(new BasicStroke(1f));
        int gridLines = 5;
        for (int i = 0; i <= gridLines; i++) {
            int y = top + (int) (plotHeight * (i / (double) gridLines));
            g.drawLine(left, y, left + plotWidth, y);
        }

        g.setColor(Color.decode("#111827"));
        g.setStroke(new BasicStroke(2f));
        g.drawLine(left, top, left, top + plotHeight);
        g.drawLine(left, top + plotHeight, left + plotWidth, top + plotHeight);

        g.setFont(new Font("SansSerif", Font.BOLD, 16));
        g.drawString(spec.title, left, 25);
        g.setFont(new Font("SansSerif", Font.PLAIN, 12));
        g.drawString(spec.xLabel, left + plotWidth / 2 - 30, height - 20);
        g.drawString(spec.yLabel, 10, top + plotHeight / 2);

        drawAxisTicks(g, left, top, plotWidth, plotHeight, minX, maxX, minY, maxY);

        for (int s = 0; s < series.size(); s++) {
            List<Double> ys = series.get(s);
            Color color = colors.get(s);
            g.setColor(color);
            for (int i = 0; i < xs.size() && i < ys.size(); i++) {
                double xVal = xs.get(i);
                double yVal = ys.get(i);
                int x = left + (int) ((xVal - minX) / (maxX - minX) * plotWidth);
                int y = top + plotHeight - (int) ((yVal - minY) / (maxY - minY) * plotHeight);
                g.fillOval(x - 3, y - 3, 6, 6);
            }
        }

        int legendX = left + plotWidth - 160;
        int legendY = top + 10;
        g.setFont(new Font("SansSerif", Font.PLAIN, 12));
        for (int i = 0; i < labels.size(); i++) {
            g.setColor(colors.get(i));
            g.fillRect(legendX, legendY + i * 18 - 8, 10, 10);
            g.setColor(Color.decode("#111827"));
            g.drawString(labels.get(i), legendX + 15, legendY + i * 18);
        }

        g.dispose();
        ImageIO.write(image, "png", outPath.toFile());
    }

    static void drawAxisTicks(Graphics2D g, int left, int top, int plotWidth, int plotHeight,
                              double minX, double maxX, double minY, double maxY) {
        g.setFont(new Font("SansSerif", Font.PLAIN, 11));
        g.setColor(Color.decode("#374151"));

        int ticks = 5;
        for (int i = 0; i <= ticks; i++) {
            double ratio = i / (double) ticks;
            double xVal = minX + (maxX - minX) * ratio;
            int x = left + (int) (plotWidth * ratio);
            g.drawLine(x, top + plotHeight, x, top + plotHeight + 4);
            String label = formatTick(xVal);
            int labelWidth = g.getFontMetrics().stringWidth(label);
            g.drawString(label, x - labelWidth / 2, top + plotHeight + 18);

            double yVal = minY + (maxY - minY) * (1.0 - ratio);
            int y = top + (int) (plotHeight * ratio);
            g.drawLine(left - 4, y, left, y);
            String yLabel = formatTick(yVal);
            int yLabelWidth = g.getFontMetrics().stringWidth(yLabel);
            g.drawString(yLabel, left - 8 - yLabelWidth, y + 4);
        }
    }

    static String formatTick(double value) {
        if (Math.abs(value) >= 1000) {
            return String.format(Locale.ROOT, "%.0f", value);
        }
        if (Math.abs(value) >= 100) {
            return String.format(Locale.ROOT, "%.1f", value);
        }
        if (Math.abs(value) >= 10) {
            return String.format(Locale.ROOT, "%.2f", value);
        }
        return String.format(Locale.ROOT, "%.3f", value);
    }

    static double min(List<Double> values) {
        double min = Double.POSITIVE_INFINITY;
        for (double v : values) {
            min = Math.min(min, v);
        }
        return min == Double.POSITIVE_INFINITY ? 0.0 : min;
    }

    static double max(List<Double> values) {
        double max = Double.NEGATIVE_INFINITY;
        for (double v : values) {
            max = Math.max(max, v);
        }
        return max == Double.NEGATIVE_INFINITY ? 1.0 : max;
    }

    static double maxSeries(List<List<Double>> series) {
        double max = Double.NEGATIVE_INFINITY;
        for (List<Double> values : series) {
            max = Math.max(max, max(values));
        }
        return max == Double.NEGATIVE_INFINITY ? 1.0 : max;
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
}
