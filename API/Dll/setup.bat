@echo off
setlocal enabledelayedexpansion

echo ============================================
echo  GwNexus DLL Setup Script
echo ============================================
echo.

:: Get the directory where this script is located
set "SCRIPT_DIR=%~dp0"
set "DEPS_DIR=%SCRIPT_DIR%Dependencies"
set "BUILD_DIR=%SCRIPT_DIR%build"

:: Check if git is available
where git >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Git is not installed or not in PATH.
    echo Please install Git from https://git-scm.com/
    pause
    exit /b 1
)

:: Check if cmake is available
where cmake >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] CMake is not installed or not in PATH.
    echo Please install CMake from https://cmake.org/download/
    pause
    exit /b 1
)

echo [INFO] Dependencies directory: %DEPS_DIR%
echo.

:: Create Dependencies directory if needed
if not exist "%DEPS_DIR%" (
    echo [INFO] Creating Dependencies directory...
    mkdir "%DEPS_DIR%"
)

cd /d "%DEPS_DIR%"

:: ============================================
:: Download MinHook
:: ============================================
echo.
echo [1/4] Checking MinHook...
if exist "minhook" (
    echo       MinHook already exists, skipping.
) else (
    echo       Cloning MinHook from GitHub...
    git clone --depth 1 https://github.com/TsudaKageyu/minhook.git minhook
    if %errorlevel% neq 0 (
        echo [ERROR] Failed to clone MinHook
        pause
        exit /b 1
    )
    :: Remove .git folder to avoid submodule issues
    rmdir /s /q "minhook\.git" 2>nul
    echo       MinHook downloaded successfully.
)

:: ============================================
:: Download DirectXTex
:: ============================================
echo.
echo [2/4] Checking DirectXTex...
if exist "directxtex" (
    echo       DirectXTex already exists, skipping.
) else (
    echo       Cloning DirectXTex from GitHub...
    git clone --depth 1 https://github.com/microsoft/DirectXTex.git directxtex
    if %errorlevel% neq 0 (
        echo [ERROR] Failed to clone DirectXTex
        pause
        exit /b 1
    )
    :: Remove .git folder to avoid submodule issues
    rmdir /s /q "directxtex\.git" 2>nul
    echo       DirectXTex downloaded successfully.
)

:: ============================================
:: Download ImGui
:: ============================================
echo.
echo [3/4] Checking ImGui...
if exist "imgui" (
    echo       ImGui already exists, skipping.
) else (
    echo       Cloning ImGui from GitHub...
    git clone --depth 1 https://github.com/ocornut/imgui.git imgui
    if %errorlevel% neq 0 (
        echo [ERROR] Failed to clone ImGui
        pause
        exit /b 1
    )
    :: Remove .git folder to avoid submodule issues
    rmdir /s /q "imgui\.git" 2>nul
    echo       ImGui downloaded successfully.
)

:: ============================================
:: Download nlohmann/json
:: ============================================
echo.
echo [4/4] Checking nlohmann/json...
if exist "json" (
    echo       json already exists, skipping.
) else (
    echo       Cloning nlohmann/json from GitHub...
    git clone --depth 1 https://github.com/nlohmann/json.git json
    if %errorlevel% neq 0 (
        echo [ERROR] Failed to clone nlohmann/json
        pause
        exit /b 1
    )
    :: Remove .git folder to avoid submodule issues
    rmdir /s /q "json\.git" 2>nul
    echo       nlohmann/json downloaded successfully.
)

:: ============================================
:: Find Visual Studio
:: ============================================
echo.
echo ============================================
echo  Looking for Visual Studio...
echo ============================================

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VS_PATH="

if exist "%VSWHERE%" (
    for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do (
        set "VS_PATH=%%i"
    )
)

if "%VS_PATH%"=="" (
    echo [ERROR] Visual Studio with C++ tools not found.
    echo         Please install Visual Studio with "Desktop development with C++" workload.
    echo         Download from: https://visualstudio.microsoft.com/
    pause
    exit /b 1
)

echo [INFO] Found Visual Studio: %VS_PATH%

:: ============================================
:: Configure and Build with CMake
:: ============================================
echo.
echo ============================================
echo  Building GwNexus DLL...
echo ============================================

cd /d "%SCRIPT_DIR%"

:: Create build directory
if not exist "%BUILD_DIR%" (
    mkdir "%BUILD_DIR%"
)

cd /d "%BUILD_DIR%"

:: Configure CMake (32-bit)
echo.
echo [INFO] Configuring CMake (Win32)...
cmake -G "Visual Studio 17 2022" -A Win32 ..
if %errorlevel% neq 0 (
    echo [WARNING] VS 2022 not found, trying VS 2019...
    cmake -G "Visual Studio 16 2019" -A Win32 ..
    if %errorlevel% neq 0 (
        echo [ERROR] CMake configuration failed
        pause
        exit /b 1
    )
)

:: Build Debug
echo.
echo [INFO] Building Debug configuration...
cmake --build . --config Debug --parallel
if %errorlevel% neq 0 (
    echo [ERROR] Debug build failed
    pause
    exit /b 1
)
echo [SUCCESS] Debug build completed!

:: Build Release
echo.
echo [INFO] Building Release configuration...
cmake --build . --config Release --parallel
if %errorlevel% neq 0 (
    echo [ERROR] Release build failed
    pause
    exit /b 1
)
echo [SUCCESS] Release build completed!

:: ============================================
:: Summary
:: ============================================
echo.
echo ============================================
echo  Build Complete!
echo ============================================
echo.
echo Output files:
echo   - Debug:   %SCRIPT_DIR%Debug\GwNexus.dll
echo   - Release: %SCRIPT_DIR%Release\GwNexus.dll
echo.
echo Dependencies installed:
echo   - MinHook (TsudaKageyu)
echo   - DirectXTex (Microsoft)
echo   - ImGui (ocornut)
echo   - nlohmann/json
echo.
echo Note: DirectX (d3d9.lib) is provided by Windows SDK (included with Visual Studio)
echo.

pause
exit /b 0
