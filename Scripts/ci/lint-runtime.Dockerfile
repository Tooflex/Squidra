# Ubuntu 24.04 ARM64 manifest used to qualify the Linux lint runtime locally.
FROM ubuntu@sha256:19cad59657037cffa0ac9a48107019b768900ff1071140965827513ac866bd5e
RUN apt-get update && apt-get install -y --no-install-recommends python3 libcurl4t64 libstdc++6 libxml2 && rm -rf /var/lib/apt/lists/*
