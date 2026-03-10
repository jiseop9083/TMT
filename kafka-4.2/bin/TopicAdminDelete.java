import org.apache.kafka.clients.admin.Admin;
import org.apache.kafka.clients.admin.AdminClientConfig;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.FileReader;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.ArrayList;
import java.util.List;
import java.util.Properties;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

public class TopicAdminDelete {
    public static void main(String[] args) throws Exception {
        String bootstrap = arg(args, "--bootstrap-server", null);
        String topicListFile = arg(args, "--topic-list-file", null);
        String outLog = arg(args, "--out-log", null);
        int parallelism = Integer.parseInt(arg(args, "--parallelism", "12"));
        int timeoutSec = Integer.parseInt(arg(args, "--timeout-sec", "120"));

        if (bootstrap == null || topicListFile == null || outLog == null) {
            throw new IllegalArgumentException("Required args: --bootstrap-server --topic-list-file --out-log");
        }

        List<String> topics = readTopics(topicListFile);
        if (topics.isEmpty()) {
            try (PrintWriter w = new PrintWriter(new BufferedWriter(new FileWriter(outLog, false)))) {
                w.println("[delete-summary] requested=0 ok=0 fail=0");
            }
            return;
        }

        Properties props = new Properties();
        props.put(AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrap);
        props.put(AdminClientConfig.REQUEST_TIMEOUT_MS_CONFIG, String.valueOf(timeoutSec * 1000));
        props.put(AdminClientConfig.DEFAULT_API_TIMEOUT_MS_CONFIG, String.valueOf(timeoutSec * 1000));
        props.put(AdminClientConfig.RETRIES_CONFIG, "0");

        int ok = 0;
        int fail = 0;
        try (PrintWriter log = new PrintWriter(new BufferedWriter(new FileWriter(outLog, false)));
             Admin admin = Admin.create(props)) {
            ExecutorService pool = Executors.newFixedThreadPool(Math.max(1, parallelism));
            List<Future<Boolean>> futures = new ArrayList<>();
            for (String topic : topics) {
                futures.add(pool.submit(new DeleteTask(admin, topic, timeoutSec, log)));
            }
            pool.shutdown();

            for (Future<Boolean> f : futures) {
                try {
                    if (Boolean.TRUE.equals(f.get())) ok++;
                    else fail++;
                } catch (ExecutionException e) {
                    fail++;
                }
            }
            pool.awaitTermination(timeoutSec + 30L, TimeUnit.SECONDS);

            log.printf("[delete-summary] requested=%d ok=%d fail=%d%n", topics.size(), ok, fail);
            log.flush();
        }
    }

    private static class DeleteTask implements Callable<Boolean> {
        private final Admin admin;
        private final String topic;
        private final int timeoutSec;
        private final PrintWriter log;

        DeleteTask(Admin admin, String topic, int timeoutSec, PrintWriter log) {
            this.admin = admin;
            this.topic = topic;
            this.timeoutSec = timeoutSec;
            this.log = log;
        }

        @Override
        public Boolean call() {
            try {
                admin.deleteTopics(List.of(topic)).all().get(timeoutSec, TimeUnit.SECONDS);
                synchronized (log) {
                    log.printf("[delete-ok] topic=%s%n", topic);
                    log.flush();
                }
                return true;
            } catch (Exception e) {
                synchronized (log) {
                    log.printf("[delete-fail] topic=%s error=%s%n", topic, e.getClass().getSimpleName());
                    log.flush();
                }
                return false;
            }
        }
    }

    private static List<String> readTopics(String file) throws Exception {
        List<String> topics = new ArrayList<>();
        try (BufferedReader br = new BufferedReader(new FileReader(file))) {
            String line;
            while ((line = br.readLine()) != null) {
                String t = line.trim();
                if (!t.isEmpty()) topics.add(t);
            }
        }
        return topics;
    }

    private static String arg(String[] args, String key, String def) {
        for (int i = 0; i < args.length - 1; i++) {
            if (key.equals(args[i])) return args[i + 1];
        }
        return def;
    }
}
