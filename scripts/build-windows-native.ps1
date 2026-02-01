# Snapclient Windows Native Build Script
# Requires: Windows 10/11, PowerShell 5.1+
# Run as Administrator for Visual Studio installation

param(
    [switch]$SkipVSInstall = $false
)

$ErrorActionPreference = "Stop"

Write-Host "=== Snapclient Windows Build Script ===" -ForegroundColor Cyan
Write-Host ""

# Check if running as admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $SkipVSInstall) {
    Write-Warning "Not running as Administrator. Visual Studio installation will be skipped."
    Write-Host "Re-run as Administrator to install Visual Studio automatically, or use -SkipVSInstall to continue."
    $SkipVSInstall = $true
}

# Set working directory
$workDir = "$env:USERPROFILE\snapcast-build"
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Set-Location $workDir

Write-Host "Working directory: $workDir" -ForegroundColor Green
Write-Host ""

# Step 1: Check/Install Chocolatey
Write-Host "[1/6] Checking Chocolatey..." -ForegroundColor Yellow
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Chocolatey..."
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    refreshenv
} else {
    Write-Host "Chocolatey already installed." -ForegroundColor Green
}

# Step 2: Install Git and CMake
Write-Host "`n[2/6] Installing Git and CMake..." -ForegroundColor Yellow
choco install -y git cmake --no-progress
refreshenv

# Step 3: Check/Install Visual Studio Build Tools
Write-Host "`n[3/6] Checking Visual Studio..." -ForegroundColor Yellow
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -property installationPath
    if ($vsPath) {
        Write-Host "Visual Studio found at: $vsPath" -ForegroundColor Green
    } else {
        Write-Host "Visual Studio not found." -ForegroundColor Red
        $SkipVSInstall = $false
    }
} else {
    $SkipVSInstall = $false
}

if (-not $SkipVSInstall) {
    Write-Host "Installing Visual Studio Build Tools 2022..."
    Write-Host "This may take 10-20 minutes..." -ForegroundColor Cyan
    choco install -y visualstudio2022buildtools --package-parameters "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --passive" --no-progress
    refreshenv
}

# Step 4: Install/Setup vcpkg
Write-Host "`n[4/6] Setting up vcpkg..." -ForegroundColor Yellow
$vcpkgDir = "$workDir\vcpkg"
if (-not (Test-Path "$vcpkgDir\vcpkg.exe")) {
    Write-Host "Cloning vcpkg..."
    git clone https://github.com/Microsoft/vcpkg.git $vcpkgDir
    & "$vcpkgDir\bootstrap-vcpkg.bat"
} else {
    Write-Host "vcpkg already installed." -ForegroundColor Green
}

Write-Host "Installing Windows dependencies via vcpkg..."
Write-Host "This may take 15-30 minutes on first run..." -ForegroundColor Cyan
& "$vcpkgDir\vcpkg.exe" install libflac libvorbis opus soxr --triplet x64-windows

# Step 5: Clone Snapcast
Write-Host "`n[5/6] Cloning Snapcast repository..." -ForegroundColor Yellow
$snapcastDir = "$workDir\snapcast"
if (-not (Test-Path $snapcastDir)) {
    git clone https://github.com/badaix/snapcast.git $snapcastDir
} else {
    Write-Host "Snapcast already cloned. Pulling latest..." -ForegroundColor Green
    Set-Location $snapcastDir
    git pull
}

# Step 6: Build Snapclient
Write-Host "`n[6/6] Building Snapclient..." -ForegroundColor Yellow
Set-Location $snapcastDir

$buildDir = "build-windows"
if (Test-Path $buildDir) {
    Remove-Item -Recurse -Force $buildDir
}
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
Set-Location $buildDir

Write-Host "Running CMake configure..."
cmake .. `
    -DCMAKE_TOOLCHAIN_FILE="$vcpkgDir\scripts\buildsystems\vcpkg.cmake" `
    -DVCPKG_TARGET_TRIPLET=x64-windows `
    -DCMAKE_BUILD_TYPE=Release `
    -DBUILD_SERVER=OFF `
    -DBUILD_CLIENT=ON `
    -DBUILD_WITH_PULSE=OFF `
    -DBUILD_WITH_JACK=OFF `
    -DBUILD_WITH_PIPEWIRE=OFF `
    -DBUILD_TESTS=OFF

if ($LASTEXITCODE -ne 0) {
    Write-Error "CMake configuration failed!"
    exit 1
}

Write-Host "Building (this may take 5-10 minutes)..."
cmake --build . --config Release --parallel

if ($LASTEXITCODE -ne 0) {
    Write-Error "Build failed!"
    exit 1
}

# Copy binary and DLLs to dist
$distDir = "$snapcastDir\dist\windows"
New-Item -ItemType Directory -Force -Path $distDir | Out-Null

Copy-Item "Release\snapclient.exe" $distDir -Force

# Copy required DLLs from vcpkg
$vcpkgBinDir = "$vcpkgDir\installed\x64-windows\bin"
$requiredDlls = @(
    "FLAC.dll",
    "ogg.dll",
    "opus.dll",
    "soxr.dll",
    "vorbis.dll",
    "vorbisenc.dll"
)

foreach ($dll in $requiredDlls) {
    $dllPath = "$vcpkgBinDir\$dll"
    if (Test-Path $dllPath) {
        Copy-Item $dllPath $distDir -Force
        Write-Host "Copied $dll" -ForegroundColor Gray
    } else {
        Write-Warning "DLL not found: $dll"
    }
}

Write-Host ""
Write-Host "=== Build Complete! ===" -ForegroundColor Green
Write-Host ""
Write-Host "Binary location: $distDir\snapclient.exe" -ForegroundColor Cyan
Write-Host ""
Write-Host "Test the binary:"
Write-Host "  cd $distDir"
Write-Host "  .\snapclient.exe --version"
Write-Host ""

# Test the binary
Set-Location $distDir
& ".\snapclient.exe" --version
