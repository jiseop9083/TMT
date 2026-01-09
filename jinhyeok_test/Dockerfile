FROM eclipse-temurin:17-jdk

# async-profiler 복사
COPY async-profiler-2.9-linux-arm64 /async-profiler

# Producer jar 복사
COPY producer.jar /app/
COPY kafka-clients-3.9.0.jar /app/
COPY slf4j-api-1.7.36.jar /app/


# 실행 스크립트
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
