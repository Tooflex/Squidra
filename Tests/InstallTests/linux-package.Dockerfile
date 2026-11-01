# Official ARM64 manifests resolved on 1 November 2026.
FROM node@sha256:fff5780b02872b018a9537ffd733e95a9753cb79672b39e6233410f1d8652ab2 AS node
FROM swift@sha256:4e1500a6490956ef1cb97cb9f208346475c0c43111bb1adefee1c2cf5dba3e21 AS builder
RUN apt-get update && apt-get install -y --no-install-recommends python3 && rm -rf /var/lib/apt/lists/*
COPY --from=node /usr/local/ /usr/local/
FROM ubuntu@sha256:19cad59657037cffa0ac9a48107019b768900ff1071140965827513ac866bd5e AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends python3 libcurl4t64 libstdc++6 libatomic1 && rm -rf /var/lib/apt/lists/*
COPY --from=node /usr/local/bin/node /usr/local/bin/node
