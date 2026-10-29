@echo off
setlocal
cd /d "%~dp0"
echo ==========================================
echo Windows Image Compressor - EXE Builder
echo ==========================================
where py >nul 2>nul
if errorlevel 1 (
  echo ERROR: Python launcher "py" was not found.
  echo Install Python 3.11 or 3.12 from python.org and enable Add Python to PATH.
  pause
  exit /b 1
)
echo [1/3] Upgrading pip...
py -m pip install --upgrade pip
if errorlevel 1 goto fail
echo [2/3] Installing requirements...
py -m pip install -r requirements.txt
if errorlevel 1 goto fail
echo [3/3] Building EXE...
py -m PyInstaller --noconfirm --clean --onefile --windowed --name WindowsImageCompressor image_compressor.py
if errorlevel 1 goto fail
echo.
echo BUILD SUCCESS!
echo EXE location: %~dp0dist\WindowsImageCompressor.exe
pause
exit /b 0
:fail
echo.
echo BUILD FAILED. Copy the error messages above for troubleshooting.
pause
exit /b 1
