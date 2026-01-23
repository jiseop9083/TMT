FROM eclipse-temurin:21-jdk

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-matplotlib \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
