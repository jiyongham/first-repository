#!/bin/bash
echo "=== Deploy Start ==="
cp -r dist/* /opt/deploy/
echo "배포 완료! $(date)"
ls -la /opt/deploy/
