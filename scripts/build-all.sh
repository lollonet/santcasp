#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

echo "==============================================="
echo "Building Snapclient for Linux and Windows"
echo "==============================================="
echo ""

# Build Docker image
echo "==> Building Docker image..."
docker build -t snapcast-builder -f "$REPO_ROOT/docker/Dockerfile.build" "$REPO_ROOT"
echo ""

# Build for Linux
echo "==> Building snapclient for Linux x86_64..."
docker run --rm -v "$REPO_ROOT:/snapcast" snapcast-builder bash -c "
  set -e
  cd /snapcast
  mkdir -p build-linux && cd build-linux
  cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SERVER=OFF \
    -DBUILD_CLIENT=ON \
    -DBUILD_WITH_PULSE=OFF \
    -DBUILD_WITH_JACK=OFF \
    -DBUILD_WITH_PIPEWIRE=OFF \
    -DBUILD_TESTS=OFF \
    -DBOOST_ROOT=/opt/boost_1_90_0
  cmake --build . --parallel 4
  strip /snapcast/bin/snapclient
  echo 'Linux build complete: /snapcast/bin/snapclient'
  ls -lh /snapcast/bin/snapclient
"
echo ""

# Build for Windows
echo "==> Building snapclient for Windows x86_64..."
docker run --rm -v "$REPO_ROOT:/snapcast" snapcast-builder bash -c "
  set -e
  cd /snapcast
  mkdir -p build-windows && cd build-windows
  cmake .. \
    -DCMAKE_TOOLCHAIN_FILE=/opt/vcpkg/scripts/buildsystems/vcpkg.cmake \
    -DVCPKG_TARGET_TRIPLET=x64-mingw-dynamic \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_EXE_LINKER_FLAGS="-static-libgcc -static-libstdc++" \
    -DBUILD_SERVER=OFF \
    -DBUILD_CLIENT=ON \
    -DBUILD_WITH_SSL=OFF \
    -DBUILD_WITH_PULSE=OFF \
    -DBUILD_WITH_JACK=OFF \
    -DBUILD_WITH_PIPEWIRE=OFF \
    -DBUILD_TESTS=OFF \
    -DBOOST_ROOT=/opt/boost_1_90_0
  cmake --build . --parallel 4
  x86_64-w64-mingw32-strip /snapcast/bin/snapclient.exe
  echo 'Windows build complete: /snapcast/bin/snapclient.exe'
  ls -lh /snapcast/bin/snapclient.exe
"
echo ""

# Copy to dist directory
echo "==> Copying binaries to dist/..."
mkdir -p "$REPO_ROOT/dist/linux" "$REPO_ROOT/dist/windows"
cp "$REPO_ROOT/bin/snapclient" "$REPO_ROOT/dist/linux/"
cp "$REPO_ROOT/bin/snapclient.exe" "$REPO_ROOT/dist/windows/"

echo ""
echo "==============================================="
echo "Build complete!"
echo "==============================================="
echo "Linux binary:   $REPO_ROOT/dist/linux/snapclient"
ls -lh "$REPO_ROOT/dist/linux/snapclient"
echo ""
echo "Windows binary: $REPO_ROOT/dist/windows/snapclient.exe"
ls -lh "$REPO_ROOT/dist/windows/snapclient.exe"
echo ""
echo "Test commands:"
echo "  Linux:   ./dist/linux/snapclient --version"
echo "  Windows: wine dist/windows/snapclient.exe --version"
echo "==============================================="
