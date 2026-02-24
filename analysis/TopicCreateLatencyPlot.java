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
import java.util.List;
import java.util.Locale;

import javax.imageio.ImageIO;

public class TopicCreateLatencyPlot {
    static class Point {
        final int seq;
        final Double value;

        Point(int seq, Double value) {
            this.seq = seq;
            this.value = value;
        }
    }

    static class Row {
        final int globalSeq;
        final Double e2eMs;
        final Double onMetadataMs;
        final Double createTopicUs;

        Row(int globalSeq, Double e2eMs, Double onMetadataMs, Double createTopicUs) {
            this.globalSeq = globalSeq;
            this.e2eMs = e2eMs;
            this.onMetadataMs = onMetadataMs;
            this.createTopicUs = createTopicUs;
        }
    }

    public static void main(String[] args) throws Exception {
        System.setProperty("java.awt.headless", "true");

        String inputDirArg = "kafka-4.2/output/topic_create_latency";
        String inputCsvArg = "";
        String outputDirArg = "kafka-4.2/figures/create-topic-latency-test";
        Double e2eMinMs = 0.0;
        Double e2eMaxMs = 100.0;
        Double onMetadataMinMs = 0.0;
        Double onMetadataMaxMs = 100.0;
        Double createTopicMinUs = 0.0;
        Double createTopicMaxUs = 800.0;

        for (int i = 0; i < args.length; i++) {
            String arg = args[i];
            if ("--input-dir".equals(arg) && i + 1 < args.length) {
                inputDirArg = args[++i];
            } else if ("--input-csv".equals(arg) && i + 1 < args.length) {
                inputCsvArg = args[++i];
            } else if ("--output-dir".equals(arg) && i + 1 < args.length) {
                outputDirArg = args[++i];
            } else if ("--e2e-min-ms".equals(arg) && i + 1 < args.length) {
                e2eMinMs = Double.parseDouble(args[++i]);
            } else if ("--e2e-max-ms".equals(arg) && i + 1 < args.length) {
                e2eMaxMs = Double.parseDouble(args[++i]);
            } else if ("--broker-metadata-update-min-ms".equals(arg) && i + 1 < args.length) {
                onMetadataMinMs = Double.parseDouble(args[++i]);
            } else if ("--broker-metadata-update-max-ms".equals(arg) && i + 1 < args.length) {
                onMetadataMaxMs = Double.parseDouble(args[++i]);
            } else if ("--controller-topic-creation-min-us".equals(arg) && i + 1 < args.length) {
                createTopicMinUs = Double.parseDouble(args[++i]);
            } else if ("--controller-topic-creation-max-us".equals(arg) && i + 1 < args.length) {
                createTopicMaxUs = Double.parseDouble(args[++i]);
            } else if ("--help".equals(arg) || "-h".equals(arg)) {
                System.out.println(
                        "Usage: java TopicCreateLatencyPlot [--input-dir <path>] [--input-csv <path>] [--output-dir <path>]\n" +
                        "       [--e2e-min-ms <v>] [--e2e-max-ms <v>]\n" +
                        "       [--broker-metadata-update-min-ms <v>] [--broker-metadata-update-max-ms <v>]\n" +
                        "       [--controller-topic-creation-min-us <v>] [--controller-topic-creation-max-us <v>]");
                return;
            } else {
                throw new IllegalArgumentException("Unknown argument: " + arg);
            }
        }

        Path outputDir = Paths.get(outputDirArg);
        Files.createDirectories(outputDir);

        List<Row> rows;
        if (!inputCsvArg.isEmpty()) {
            Path inputCsv = Paths.get(inputCsvArg);
            if (!Files.exists(inputCsv)) {
                throw new IllegalArgumentException("CSV not found: " + inputCsv);
            }
            rows = readRowsFromSingleCsv(inputCsv, 0);
        } else {
            Path inputDir = Paths.get(inputDirArg);
            rows = readRowsFromAllCsvs(inputDir);
        }

        if (rows.isEmpty()) {
            throw new IllegalStateException("No usable rows found.");
        }

        drawScatter(
                toPoints(rows, "e2e"),
                "Topic Create E2E Latency",
                "E2E Latency (ms)",
                outputDir.resolve("e2e_latency_ms.png"),
                new Color(47, 111, 223),
                e2eMinMs,
                e2eMaxMs);
        drawScatter(
                toPoints(rows, "onMeta"),
                "Broker onMetadataUpdate Duration",
                "Broker Metadata Update Processing Time (ms)",
                outputDir.resolve("broker_metadata_update_ms.png"),
                new Color(15, 157, 88),
                onMetadataMinMs,
                onMetadataMaxMs);
        drawScatter(
                toPoints(rows, "createTopic"),
                "Controller Topic Creation Processing Time",
                "Controller Topic Creation Processing Time (us)",
                outputDir.resolve("controller_topic_creation_us.png"),
                new Color(209, 122, 0),
                createTopicMinUs,
                createTopicMaxUs);

        System.out.println("Wrote plots to " + outputDir);
    }

    static List<Row> readRowsFromAllCsvs(Path dir) throws IOException {
        if (!Files.isDirectory(dir)) {
            throw new IllegalArgumentException("Input dir not found: " + dir);
        }
        List<Path> csvs = new ArrayList<>();
        try (DirectoryStream<Path> ds = Files.newDirectoryStream(dir, "topic_create_requests_*.csv")) {
            for (Path p : ds) {
                if (Files.isRegularFile(p)) {
                    csvs.add(p);
                }
            }
        }
        csvs.sort(Comparator.naturalOrder());
        if (csvs.isEmpty()) {
            throw new IllegalStateException("No topic_create_requests_*.csv found under: " + dir);
        }

        List<Row> all = new ArrayList<>();
        for (Path csv : csvs) {
            // Keep original seq range per run (e.g., 1..3000) and overlay runs on the same x-axis.
            List<Row> rows = readRowsFromSingleCsv(csv, 0);
            all.addAll(rows);
        }
        return all;
    }

    static List<Row> readRowsFromSingleCsv(Path csvPath, int seqOffset) throws IOException {
        List<Row> rows = new ArrayList<>();
        try (BufferedReader reader = Files.newBufferedReader(csvPath)) {
            String header = reader.readLine();
            if (header == null) {
                return rows;
            }
            String[] headers = header.split(",", -1);
            int seqIdx = indexOf(headers, "seq");
            int statusIdx = indexOf(headers, "status");
            int e2eIdx = indexOf(headers, "e2e_latency_us");
            int onMetaIdx = indexOf(headers, "on_metadata_duration_us");
            int createIdx = indexOf(headers, "create_topic_duration_us");

            if (seqIdx < 0 || e2eIdx < 0 || onMetaIdx < 0 || createIdx < 0) {
                throw new IllegalStateException("Required columns missing in CSV: " + csvPath);
            }

            String line;
            while ((line = reader.readLine()) != null) {
                if (line.isBlank()) {
                    continue;
                }
                String[] p = line.split(",", -1);
                if (statusIdx >= 0 && statusIdx < p.length) {
                    String status = p[statusIdx].trim();
                    if (!status.isEmpty() && !"OK".equals(status)) {
                        continue;
                    }
                }

                int seq = Integer.parseInt(safeGet(p, seqIdx));
                Double e2eMs = parseNullableDouble(safeGet(p, e2eIdx), 1000.0);
                Double onMetaMs = parseNullableDouble(safeGet(p, onMetaIdx), 1000.0);
                Double createUs = parseNullableDouble(safeGet(p, createIdx), 1.0);
                rows.add(new Row(seqOffset + seq, e2eMs, onMetaMs, createUs));
            }
        }
        return rows;
    }

    static List<Point> toPoints(List<Row> rows, String metric) {
        List<Point> points = new ArrayList<>(rows.size());
        for (Row row : rows) {
            Double v;
            if ("e2e".equals(metric)) {
                v = row.e2eMs;
            } else if ("onMeta".equals(metric)) {
                v = row.onMetadataMs;
            } else if ("createTopic".equals(metric)) {
                v = row.createTopicUs;
            } else {
                v = null;
            }
            points.add(new Point(row.globalSeq, v));
        }
        return points;
    }

    static void drawScatter(List<Point> points, String title, String yLabel, Path outPath, Color pointColor,
            Double yMinOverride, Double yMaxOverride)
            throws IOException {
        int width = 1600;
        int height = 720;
        int left = 90;
        int right = 40;
        int top = 70;
        int bottom = 80;
        int plotW = width - left - right;
        int plotH = height - top - bottom;

        int minX = Integer.MAX_VALUE;
        int maxX = Integer.MIN_VALUE;
        double minY = Double.POSITIVE_INFINITY;
        double maxY = Double.NEGATIVE_INFINITY;

        for (Point p : points) {
            minX = Math.min(minX, p.seq);
            maxX = Math.max(maxX, p.seq);
            if (p.value != null) {
                minY = Math.min(minY, p.value);
                maxY = Math.max(maxY, p.value);
            }
        }

        if (yMinOverride != null && yMaxOverride != null && yMaxOverride <= yMinOverride) {
            throw new IllegalArgumentException("y max must be greater than y min for " + title);
        }
        if (yMinOverride != null) {
            minY = yMinOverride;
        }
        if (yMaxOverride != null) {
            maxY = yMaxOverride;
        }

        if (!Double.isFinite(minY) || !Double.isFinite(maxY)) {
            minY = 0.0;
            maxY = 1.0;
        } else if (yMinOverride == null && yMaxOverride == null && Math.abs(maxY - minY) < 1e-12) {
            maxY = minY + 1.0;
        } else if (yMinOverride == null && yMaxOverride == null) {
            double pad = (maxY - minY) * 0.06;
            minY -= pad;
            maxY += pad;
        }
        if (maxX == minX) {
            maxX = minX + 1;
        }

        BufferedImage img = new BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = img.createGraphics();
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
        g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_ON);

        g.setColor(Color.WHITE);
        g.fillRect(0, 0, width, height);

        g.setColor(new Color(228, 232, 238));
        g.setStroke(new BasicStroke(1f));
        int yTicks = 6;
        for (int i = 0; i <= yTicks; i++) {
            int y = top + (int) Math.round(plotH * (i / (double) yTicks));
            g.drawLine(left, y, left + plotW, y);
        }

        g.setColor(new Color(40, 44, 52));
        g.setStroke(new BasicStroke(1.4f));
        g.drawLine(left, top + plotH, left + plotW, top + plotH);
        g.drawLine(left, top, left, top + plotH);

        g.setFont(new Font("SansSerif", Font.BOLD, 24));
        g.drawString(title, left, 40);

        g.setFont(new Font("SansSerif", Font.PLAIN, 16));
        g.drawString("Topic Sequence (seq)", left + plotW / 2 - 80, height - 24);
        g.drawString(yLabel, 14, top + plotH / 2);

        g.setFont(new Font("SansSerif", Font.PLAIN, 14));
        for (int i = 0; i <= yTicks; i++) {
            double v = maxY - (maxY - minY) * (i / (double) yTicks);
            int y = top + (int) Math.round(plotH * (i / (double) yTicks));
            g.setColor(new Color(70, 74, 82));
            g.drawString(String.format(Locale.ROOT, "%.2f", v), 18, y + 5);
        }

        int xTicks = 10;
        for (int i = 0; i <= xTicks; i++) {
            double xVal = minX + (maxX - minX) * (i / (double) xTicks);
            int x = left + (int) Math.round(plotW * (i / (double) xTicks));
            g.setColor(new Color(70, 74, 82));
            g.drawString(String.valueOf((int) Math.round(xVal)), x - 16, top + plotH + 24);
        }

        g.setColor(pointColor);
        for (Point p : points) {
            if (p.value == null) {
                continue;
            }
            if (p.value < minY || p.value > maxY) {
                continue;
            }
            double xn = (p.seq - minX) / (double) (maxX - minX);
            double yn = (p.value - minY) / (maxY - minY);
            int x = left + (int) Math.round(plotW * xn);
            int y = top + plotH - (int) Math.round(plotH * yn);
            g.fillOval(x - 2, y - 2, 4, 4);
        }

        g.dispose();
        ImageIO.write(img, "png", outPath.toFile());
    }

    static String safeGet(String[] parts, int idx) {
        if (idx < 0 || idx >= parts.length) {
            return "";
        }
        return parts[idx].trim();
    }

    static Double parseNullableDouble(String raw, double divisor) {
        if (raw == null || raw.isEmpty()) {
            return null;
        }
        return Double.parseDouble(raw) / divisor;
    }

    static int indexOf(String[] headers, String name) {
        for (int i = 0; i < headers.length; i++) {
            if (name.equals(headers[i].trim())) {
                return i;
            }
        }
        return -1;
    }

}
