# Official Swift 6.4.2 Ubuntu 24.04 ARM64 manifest, inspected 1 November 2026.
FROM swift@sha256:4e1500a6490956ef1cb97cb9f208346475c0c43111bb1adefee1c2cf5dba3e21
# Python is the existing process-death test fixture dependency, not a server dependency.
RUN apt-get update && apt-get install -y --no-install-recommends python3 && rm -rf /var/lib/apt/lists/*
