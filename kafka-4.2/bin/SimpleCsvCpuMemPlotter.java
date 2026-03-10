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

public class SimpleCsvCpuMemPlotter {
    public static void main(String[] args) throws Exception {
        Map<String, String> a = parseArgs(args);
        String csv = required(a, "--csv");
        String out = required(a, "--out");
        String xCol = a.getOrDefault("--x-col", "sample");
        String cpuCol = a.getOrDefault("--cpu-col", "cpu_percent");
        String memCol = a.getOrDefault("--mem-col", "memory_rss_mb");
        String title = a.getOrDefault("--title", "Broker CPU and Memory");

        List<Double> xs = new ArrayList<>();
        List<Double> cpus = new ArrayList<>();
        List<Double> mems = new ArrayList<>();
        read(csv, xCol, cpuCol, memCol, xs, cpus, mems);
        if (xs.isEmpty()) throw new IllegalStateException("No numeric rows found in CSV: " + csv);
        render(xs, cpus, mems, out, title);
    }

    private static void read(String csv, String xCol, String cpuCol, String memCol,
                             List<Double> xs, List<Double> cpus, List<Double> mems) throws Exception {
        try (BufferedReader br = new BufferedReader(new FileReader(csv))) {
            String header = br.readLine();
            if (header == null) throw new IllegalStateException("Empty CSV: " + csv);
            String[] cols = header.split(",", -1);
            Map<String, Integer> idx = new HashMap<>();
            for (int i = 0; i < cols.length; i++) idx.put(cols[i].trim(), i);
            Integer xi = idx.get(xCol);
            Integer ci = idx.get(cpuCol);
            Integer mi = idx.get(memCol);
            if (xi == null || ci == null || mi == null) {
                throw new IllegalArgumentException("Missing required columns in CSV");
            }
            String line;
            while ((line = br.readLine()) != null) {
                if (line.isBlank()) continue;
                String[] p = line.split(",", -1);
                if (xi >= p.length || ci >= p.length || mi >= p.length) continue;
                try {
                    xs.add(Double.parseDouble(p[xi].trim()));
                    cpus.add(Double.parseDouble(p[ci].trim()));
                    mems.add(Double.parseDouble(p[mi].trim()));
                } catch (NumberFormatException ignore) {
                }
            }
        }
    }

    private static void render(List<Double> xs, List<Double> cpus, List<Double> mems, String outFile, String title) throws Exception {
        int width = 1200;
        int height = 700;
        int left = 90;
        int right = 40;
        int top = 50;
        int bottom = 50;
        int gap = 35;
        int panelH = (height - top - bottom - gap) / 2;
        int plotW = width - left - right;

        BufferedImage img = new BufferedImage(width, height, BufferedImage.TYPE_INT_RGB);
        Graphics2D g = img.createGraphics();
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
        g.setColor(Color.WHITE);
        g.fillRect(0, 0, width, height);

        g.setColor(Color.BLACK);
        g.setFont(new Font("SansSerif", Font.BOLD, 18));
        g.drawString(title, left, 30);

        int topY = top;
        int bottomY = top + panelH + gap;

        drawPanel(g, xs, cpus, left, topY, plotW, panelH, "CPU (%)", new Color(47, 107, 255));
        drawPanel(g, xs, mems, left, bottomY, plotW, panelH, "Memory RSS (MB)", new Color(217, 119, 6));

        g.setFont(new Font("SansSerif", Font.PLAIN, 14));
        g.setColor(Color.DARK_GRAY);
        g.drawString("sample", left + plotW / 2 - 20, height - 15);

        Path outPath = Path.of(outFile);
        if (outPath.getParent() != null) Files.createDirectories(outPath.getParent());
        ImageIO.write(img, "png", new File(outFile));
        g.dispose();
    }

    private static void drawPanel(Graphics2D g, List<Double> xs, List<Double> ys, int left, int top, int plotW, int plotH,
                                  String yLabel, Color color) {
        double minX = xs.stream().min(Double::compareTo).orElse(0.0);
        double maxX = xs.stream().max(Double::compareTo).orElse(1.0);
        double minY = ys.stream().min(Double::compareTo).orElse(0.0);
        double maxY = ys.stream().max(Double::compareTo).orElse(1.0);
        if (minX == maxX) maxX = minX + 1;
        if (minY == maxY) maxY = minY + 1;

        g.setColor(new Color(235, 235, 235));
        for (int i = 0; i <= 6; i++) {
            int y = top + (int) Math.round(i * (plotH / 6.0));
            g.drawLine(left, y, left + plotW, y);
        }

        g.setColor(Color.BLACK);
        g.setStroke(new BasicStroke(1.5f));
        g.drawLine(left, top, left, top + plotH);
        g.drawLine(left, top + plotH, left + plotW, top + plotH);
        g.setFont(new Font("SansSerif", Font.PLAIN, 13));
        g.drawString(yLabel, 10, top + plotH / 2);

        g.setColor(color);
        g.setStroke(new BasicStroke(1.8f));
        int prevX = -1;
        int prevY = -1;
        for (int i = 0; i < xs.size(); i++) {
            int x = left + (int) Math.round((xs.get(i) - minX) / (maxX - minX) * plotW);
            int y = top + plotH - (int) Math.round((ys.get(i) - minY) / (maxY - minY) * plotH);
            if (prevX >= 0) g.drawLine(prevX, prevY, x, y);
            g.fillOval(x - 2, y - 2, 4, 4);
            prevX = x;
            prevY = y;
        }
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
            if (i + 1 < args.length && !args[i + 1].startsWith("--")) out.put(k, args[++i]);
            else out.put(k, "true");
        }
        return out;
    }
}
