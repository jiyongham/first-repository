# deploy.sh
#!/bin/bash
echo "=== Deploy Start ==="
DEPLOY_DIR="/opt/myapp"
mkdir -p $DEPLOY_DIR
cp dist/app.sh $DEPLOY_DIR/app.sh
echo "배포 완료: $DEPLOY_DIR/app.sh"
$DEPLOY_DIR/app.sh
