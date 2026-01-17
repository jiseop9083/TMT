FROM eclipse-temurin:21.0.8_9-jdk

ARG KAFKA_CLIENTS_VERSION=4.1.1
ARG SLF4J_VERSION=2.0.16
ARG ASYNC_PROFILER_VERSION=3.0
ARG ASYNC_PROFILER_ARCH=linux-arm64

RUN apt-get update \
  && apt-get install -y --no-install-recommends curl ca-certificates tar \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN apt-get update \
  && apt-get install -y --no-install-recommends curl ca-certificates tar iproute2 bash \
  && rm -rf /var/lib/apt/lists/*

# Producer 소스 복사
COPY ProducerOnce.java /app/

# Kafka/SLF4J 다운로드 및 컴파일
RUN mkdir -p /app/lib /app/classes \
  && curl -L -o /app/lib/kafka-clients.jar \
    "https://repo1.maven.org/maven2/org/apache/kafka/kafka-clients/${KAFKA_CLIENTS_VERSION}/kafka-clients-${KAFKA_CLIENTS_VERSION}.jar" \
  && curl -L -o /app/lib/slf4j-api.jar \
    "https://repo1.maven.org/maven2/org/slf4j/slf4j-api/${SLF4J_VERSION}/slf4j-api-${SLF4J_VERSION}.jar" \
  && javac --release 21 -cp "/app/lib/*" -d /app/classes /app/ProducerOnce.java \
  && jar cfe /app/producer.jar ProducerOnce -C /app/classes .

# # async-profiler 다운로드
# RUN curl -L -o /tmp/async-profiler.tgz \
#     "https://github.com/async-profiler/async-profiler/releases/download/v${ASYNC_PROFILER_VERSION}/async-profiler-${ASYNC_PROFILER_VERSION}-${ASYNC_PROFILER_ARCH}.tar.gz" \
#   && mkdir -p /async-profiler \
#   && tar -xzf /tmp/async-profiler.tgz -C /tmp \
#   && mv "/tmp/async-profiler-${ASYNC_PROFILER_VERSION}-${ASYNC_PROFILER_ARCH}"/* /async-profiler/ \
#   && rm -rf /tmp/async-profiler.tgz "/tmp/async-profiler-${ASYNC_PROFILER_VERSION}-${ASYNC_PROFILER_ARCH}"

# 실행 스크립트
COPY custom_profile.jfc /custom_profile.jfc
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
