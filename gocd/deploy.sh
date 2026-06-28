#!/bin/bash
echo "=== Deploy Start ==="
DEPLOY_DIR="/opt/deploy"
mkdir -p $DEPLOY_DIR
cp -r dist/* $DEPLOY_DIR/
echo "배포 완료! $(date)"
ls -la $DEPLOY_DIR/
