# Claire Server — Docker build for DGX deployment
# 3 services: Kotlin realtime server, Python STT (Parakeet), Python TTS (Kokoro)
# No llama.cpp, no whisper.cpp native — all inference via Python servers + Claude API

# ---------- Stage 1: Build Kotlin server ----------
FROM nvidia/cuda:12.4.1-devel-ubuntu22.04 AS server-build
WORKDIR /src

RUN apt-get update && apt-get install -y \
    openjdk-21-jdk curl git git-lfs build-essential dos2unix \
    && rm -rf /var/lib/apt/lists/*

COPY . /src/claire

WORKDIR /src/claire

RUN dos2unix ./gradlew && chmod +x ./gradlew

ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
ENV GRADLE_OPTS="-Xmx2g -XX:MaxMetaspaceSize=512m"

# Initialize submodules and build fat JAR
RUN git submodule update --init --recursive 2>/dev/null || true
RUN ./gradlew clean :server:shadowJar -x test --no-build-cache --stacktrace

# ---------- Stage 2: Runtime ----------
FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04
WORKDIR /app

RUN mkdir -p /app/server /app/stt-server /app/tts-server /app/logs

# Runtime deps: Java, Python, supervisord
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    openjdk-21-jre-headless \
    python3 python3-pip python3-venv python3-dev \
    supervisor curl \
    && rm -rf /var/lib/apt/lists/*

# ---- Kotlin realtime server ----
COPY --from=server-build /src/claire/server/build/libs/*-all.jar /app/server/claire-server.jar

# ---- STT server (Parakeet) ----
WORKDIR /app/stt-server
COPY stt-server/requirements.txt ./
COPY stt-server/server.py ./

RUN python3 -m venv /opt/venv && \
    . /opt/venv/bin/activate && \
    pip install --upgrade pip setuptools wheel && \
    pip install --no-cache-dir -r requirements.txt

# ---- TTS server (Kokoro) ----
WORKDIR /app/tts-server
COPY tts-server/requirements.txt ./
COPY tts-server/server.py ./

RUN python3 -m venv /opt/tts-venv && \
    . /opt/tts-venv/bin/activate && \
    pip install --upgrade pip setuptools wheel && \
    pip install --no-cache-dir -r requirements.txt

# ---- Supervisor ----
WORKDIR /app
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

EXPOSE 8080 1236 1238

RUN echo '#!/bin/bash' > /app/start.sh && \
    echo 'exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf' >> /app/start.sh && \
    chmod +x /app/start.sh

CMD ["/app/start.sh"]
