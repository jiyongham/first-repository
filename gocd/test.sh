# test.sh
#!/bin/bash
echo "=== Test Start ==="
if [ -f dist/app.sh ]; then
  echo "app.sh 존재 확인: OK"
  exit 0
else
  echo "app.sh 없음: FAIL"
  exit 1   # 실패 시 다음 Stage 중단
fi
