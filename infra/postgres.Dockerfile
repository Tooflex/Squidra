FROM docker.io/library/postgres:17-bookworm@sha256:839fbb5a4942a7758dd93e18b42ea5649807491a0545b5eeeb8f0b8bb11857a5

# Versions verified in PGDG's bookworm indexes for both amd64 and arm64.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       postgresql-17-postgis-3=3.6.4+dfsg-2.pgdg12+1 \
       postgresql-17-postgis-3-scripts=3.6.4+dfsg-2.pgdg12+1 \
       postgresql-17-pgvector=0.8.7-1.pgdg12+1 \
    && rm -rf /var/lib/apt/lists/*
