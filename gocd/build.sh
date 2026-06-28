#!/bin/bash
echo "=== Build Start ==="
mkdir -p dist
echo "v1.0 - $(date)" > dist/version.txt
echo "=== Build Done ==="
cat dist/version.txt
