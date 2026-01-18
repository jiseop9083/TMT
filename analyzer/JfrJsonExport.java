import java.io.IOException;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

public class JfrJsonExport {
    private static final String DEFAULT_EVENTS =
            "jdk.ThreadPark,jdk.JavaMonitorEnter,jdk.JavaMonitorWait," +
            "jdk.SocketRead,jdk.SocketWrite,jdk.GCPhasePause," +
            "jdk.GarbageCollection,jdk.SafePointWait";

    public static void main(String[] args) throws Exception {
        if (args.length < 1 || "--help".equals(args[0])) {
            System.out.println(
                    "Usage: java JfrJsonExport <recording.jfr> [out.json] [--events <csv>]\n" +
                    "   or: java JfrJsonExport --out-dir <dir> [--events <csv>]");
            return;
        }

        String events = DEFAULT_EVENTS;

        if ("--out-dir".equals(args[0])) {
            String outDirArg = requireArg(args, 1, "--out-dir");
            for (int i = 2; i < args.length; i++) {
                if ("--events".equals(args[i]) && i + 1 < args.length) {
                    events = args[++i];
                } else {
                    throw new IllegalArgumentException("Unknown argument: " + args[i]);
                }
            }
            exportRunDir(Paths.get(outDirArg), events);
            return;
        }

        Path jfrPath = Paths.get(args[0]);
        Path outPath = args.length >= 2 && !args[1].startsWith("--")
                ? Paths.get(args[1])
                : defaultOutputPath(jfrPath);
        for (int i = 1; i < args.length; i++) {
            if ("--events".equals(args[i]) && i + 1 < args.length) {
                events = args[++i];
            } else {
                if (i == 1 && !args[i].startsWith("--")) {
                    continue;
                }
                throw new IllegalArgumentException("Unknown argument: " + args[i]);
            }
        }

        if (!Files.exists(jfrPath)) {
            throw new IllegalArgumentException("JFR not found: " + jfrPath);
        }
        runJfrPrint(jfrPath, outPath, events);
    }

    private static void runJfrPrint(Path jfrPath, Path outPath, String events)
            throws IOException, InterruptedException {
        List<String> cmd = new ArrayList<>();
        cmd.add("jfr");
        cmd.add("print");
        cmd.add("--json");
        cmd.add("--events");
        cmd.add(events);
        cmd.add(jfrPath.toString());

        ProcessBuilder pb = new ProcessBuilder(cmd);
        pb.redirectOutput(outPath.toFile());
        pb.redirectError(ProcessBuilder.Redirect.INHERIT);
        Process proc = pb.start();
        int code = proc.waitFor();
        if (code != 0) {
            throw new RuntimeException("jfr print failed with exit code " + code);
        }
    }

    private static Path defaultOutputPath(Path jfrPath) {
        String name = jfrPath.getFileName().toString();
        int dot = name.lastIndexOf('.');
        String base = dot > 0 ? name.substring(0, dot) : name;
        return jfrPath.resolveSibling(base + ".json");
    }

    private static String requireArg(String[] args, int index, String flag) {
        if (index >= args.length) {
            throw new IllegalArgumentException(flag + " requires a value");
        }
        return args[index];
    }

    private static void exportRunDir(Path base, String events) throws IOException, InterruptedException {
        Path runDir = findRunDir(base);
        List<Path> expDirs = iterExperimentDirs(runDir);
        if (expDirs.isEmpty()) {
            throw new IllegalStateException("No experiment directories found under " + runDir);
        }

        Path analysisDir = runDir.resolve("analysis");
        Files.createDirectories(analysisDir);

        for (Path expDir : expDirs) {
            Path jfrPath = findJfr(expDir);
            if (jfrPath == null) {
                continue;
            }
            String baseName = baseName(jfrPath.getFileName().toString());
            String outName = expDir.getFileName() + "-" + baseName + ".json";
            Path outPath = analysisDir.resolve(outName);
            runJfrPrint(jfrPath, outPath, events);
        }

        System.out.println("Wrote analysis JSONs to " + analysisDir);
    }

    private static String baseName(String name) {
        int dot = name.lastIndexOf('.');
        return dot > 0 ? name.substring(0, dot) : name;
    }

    private static Path findRunDir(Path base) throws IOException {
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

    private static List<Path> iterExperimentDirs(Path runDir) throws IOException {
        List<Path> dirs = new ArrayList<>();
        try (DirectoryStream<Path> stream = Files.newDirectoryStream(runDir)) {
            for (Path p : stream) {
                if (!Files.isDirectory(p)) continue;
                if (p.getFileName().toString().startsWith("kafka-producer-experiment-")) {
                    dirs.add(p);
                }
            }
        }
        dirs.sort(Comparator.naturalOrder());
        return dirs;
    }

    private static Path findJfr(Path expDir) throws IOException {
        Path candidate = findFirstMatching(expDir, "producer-", ".jfr");
        if (candidate != null) {
            return candidate;
        }
        return findFirstMatching(expDir, "", ".jfr");
    }

    private static Path findFirstMatching(Path dir, String prefix, String suffix) throws IOException {
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
}
