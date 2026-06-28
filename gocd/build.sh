# build.sh
#!/bin/bash
echo "=== Build Start ==="
mkdir -p dist
cp app.sh dist/app.sh
chmod +x dist/app.sh
echo "=== Build Done ==="
