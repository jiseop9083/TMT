FROM eclipse-temurin:21-jdk

WORKDIR /app/analayzer

COPY analayzer /app/analayzer

RUN javac JfrWallClockAttribution.java JfrJsonExport.java

WORKDIR /workspace

ENTRYPOINT ["java", "-cp", "/app/analayzer", "JfrWallClockAttribution"]
