import javax.imageio.ImageIO;
import java.awt.BasicStroke;
import java.awt.Color;
import java.awt.Font;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.image.BufferedImage;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class SimpleCsvLinePlotter {
    public static void main(String[] args) throws Exception {
        Map<String, String> a = parseArgs(args);
        String csv = required(a, "--csv");
        String out = required(a, "--out");
        String xCol = required(a, "--x-col");
        String yCol = required(a, "--y-col");
        String title = a.getOrDefault("--title", "Line Plot");
        String xLabel = a.getOrDefault("--x-label", "x");
        String yLabel = a.getOrDefault("--y-label", "y");
        String colorHex = a.getOrDefault("--color", "#2F6BFF");
        String style = a.getOrDefault("--style", "line");
        Double yMin = a.containsKey("--y-min") ? Double.parseDouble(a.get("--y-min")) : null;
        Double yMax = a.containsKey("--y-max") ? Double.parseDouble(a.get("--y-max")) : null;

        List<Double> xs = new ArrayList<>();
        List<Double> ys = new ArrayList<>();
        readSeries(csv, xCol, yCol, xs, ys);
        if (xs.isEmpty()) {
            throw new IllegalStateException("No numeric rows found in CSV: " + csv);
        }
        render(xs, ys, out, title, xLabel, yLabel, Color.decode(colorHex), style, yMin, yMax);
    }

    private static void readSeries(String csv, String xCol, String yCol, List<Double> xs, List<Double> ys) throws Exception {
        try (BufferedReader br = new BufferedReader(new FileReader(csv))) {
            String header = br.readLine();
            if (header == null) throw new IllegalStateException("Empty CSV: " + csv);
            String[] cols = header.split(",", -1);
            Map<String, Integer> idx = new HashMap<>();
            for (int i = 0; i < cols.length; i++) idx.put(cols[i].trim(), i);
            Integer xi = idx.get(xCol);
            Integer yi = idx.get(yCol);
            if (xi == null || yi == null) {
                throw new IllegalArgumentException("Missing columns in CSV. x=" + xCol + ", y=" + yCol);
            }

            String line;
            while ((line = br.readLine()) != null) {
                if (line.isBlank()) continue;
                String[] p = line.split(",", -1);
                if (xi >= p.length || yi >= p.length) continue;
                try {
                    double x = Double.parseDouble(p[xi].trim());
                    double y = Double.parseDouble(p[yi].trim());
                    xs.add(x);
                    ys.add(y);
                } catch (NumberFormatException ignore) {
                    // skip non-numeric rows
                }
            }
        }
    }

    private static void render(List<Double> xs, List<Double> ys, String outFile, String title, String xLabel, String yLabel, Color seriesColor,
                               String style, Double fixedYMin, Double fixedYMax) throws Exception {
        int width = 1200;
        int height = 500;
        int left = 90;
        int right = 40;
        int top = 50;
        int bottom = 70;
        int plotW = width - left - right;
        int plotH = height - top - bottom;

        double minX = xs.stream().min(Double::compareTo).orElse(0.0);
        double maxX = xs.stream().max(Double::compareTo).orElse(1.0);
        double minY = fixedYMin != null ? fixedYMin : ys.stream().min(Double::compareTo).orElse(0.0);
        double maxY = fixedYMax != null ? fixedYMax : ys.stream().max(Double::compareTo).orElse(1.0);
        if (minX == maxX) maxX = minX + 1;
        if (minY == maxY) maxY = minY + 1;

        BufferedImage img = new BufferedImage(width, height, BufferedImage.TYPE_INT_RGB);
        Graphics2D g = img.createGraphics();
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);

        g.setColor(Color.WHITE);
        g.fillRect(0, 0, width, height);

        g.setColor(new Color(235, 235, 235));
        for (int i = 0; i <= 8; i++) {
            int y = top + (int) Math.round(i * (plotH / 8.0));
            g.drawLine(left, y, left + plotW, y);
        }

        g.setColor(Color.BLACK);
        g.setStroke(new BasicStroke(1.5f));
        g.drawLine(left, top, left, top + plotH);
        g.drawLine(left, top + plotH, left + plotW, top + plotH);

        g.setFont(new Font("SansSerif", Font.BOLD, 18));
        g.drawString(title, left, 30);
        g.setFont(new Font("SansSerif", Font.PLAIN, 14));
        g.drawString(xLabel, left + plotW / 2 - 20, height - 25);
        g.drawString(yLabel, 15, top + plotH / 2);

        g.setColor(seriesColor);
        g.setStroke(new BasicStroke(2.0f));
        boolean drawLine = "line".equalsIgnoreCase(style);
        boolean drawScatter = "scatter".equalsIgnoreCase(style) || !drawLine;
        int prevX = -1;
        int prevY = -1;
        for (int i = 0; i < xs.size(); i++) {
            int x = left + (int) Math.round((xs.get(i) - minX) / (maxX - minX) * plotW);
            int y = top + plotH - (int) Math.round((ys.get(i) - minY) / (maxY - minY) * plotH);
            if (drawLine && prevX >= 0) g.drawLine(prevX, prevY, x, y);
            if (drawScatter) g.fillOval(x - 2, y - 2, 4, 4);
            prevX = x;
            prevY = y;
        }

        Path outPath = Path.of(outFile);
        if (outPath.getParent() != null) Files.createDirectories(outPath.getParent());
        ImageIO.write(img, "png", new File(outFile));
        g.dispose();
    }

    private static String required(Map<String, String> args, String key) {
        String v = args.get(key);
        if (v == null || v.isBlank()) throw new IllegalArgumentException("Missing arg: " + key);
        return v;
    }

    private static Map<String, String> parseArgs(String[] args) {
        Map<String, String> out = new HashMap<>();
        for (int i = 0; i < args.length; i++) {
            String k = args[i];
            if (!k.startsWith("--")) continue;
            if (i + 1 < args.length && !args[i + 1].startsWith("--")) {
                out.put(k, args[++i]);
            } else {
                out.put(k, "true");
            }
        }
        return out;
    }
}
