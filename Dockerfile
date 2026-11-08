# linux/amd64 candidate for a later NAS review. This file does not publish an image.
# Base tags are pinned. Digests are not invented here; resolve them when the image is built.

FROM golang:1.24.1-bookworm AS bridge
WORKDIR /src
COPY whatsapp-bridge/go.mod whatsapp-bridge/go.sum ./
RUN go mod download
COPY whatsapp-bridge/ ./
RUN CGO_ENABLED=1 go build -o /out/whatsapp-bridge .

FROM python:3.11-slim-bookworm
RUN useradd --uid 65532 --create-home --shell /usr/sbin/nologin app
WORKDIR /app
COPY whatsapp-mcp-server/*.py /app/whatsapp-mcp-server/
RUN pip install --no-cache-dir "mcp==1.25.0" "httpx>=0.28.1" \
    && rm -rf /root/.cache
COPY --from=bridge /out/whatsapp-bridge /app/whatsapp-bridge
COPY deploy/entrypoint.sh /app/entrypoint.sh
RUN chmod 755 /app/entrypoint.sh /app/whatsapp-bridge \
    && chown -R app:app /app
USER 65532:65532
WORKDIR /app/whatsapp-mcp-server
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    WA_INSTANCE_DIR=/var/lib/wa-instance
VOLUME ["/var/lib/wa-instance"]
ENTRYPOINT ["/app/entrypoint.sh"]
