#!/bin/bash
echo "=== Test Start ==="
if [ -f dist/version.txt ]; then
  echo "version.txt 확인: OK ✅"
  exit 0
else
  echo "version.txt 없음: FAIL ❌"
  exit 1
fi
