curl -O https://repo1.maven.org/maven2/org/apache/kafka/kafka-clients/3.9.0/kafka-clients-3.9.0.jar
curl -O https://repo1.maven.org/maven2/org/slf4j/slf4j-api/1.7.36/slf4j-api-1.7.36.jar
curl -LO https://github.com/async-profiler/async-profiler/releases/download/v2.9/async-profiler-2.9-linux-arm64.tar.gz
tar -xvf async-profiler-2.9-linux-arm64.tar.gz

javac -cp "kafka-clients-3.9.0.jar:slf4j-api-1.7.36.jar:." ProducerOnce.java
jar cfe producer.jar ProducerOnce ProducerOnce.class

docker build -t my-kafka-producer:latest .

kubectl apply -f kafka_producer_experiment_job.yaml -n kafka

rm -r async-profiler-2.9-linux-arm64
rm -r async-profiler-2.9-linux-arm64.tar.gz
rm -r kafka-clients-3.9.0.jar
rm -r producer.jar
rm -r ProducerOnce.class
rm -r slf4j-api-1.7.36.jar