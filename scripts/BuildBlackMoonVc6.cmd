@echo off
setlocal EnableExtensions

rem This script runs only inside the pinned giulioz/vc6-docker probe image.
rem Its Wine Z: drive maps the container filesystem and exposes /opt/vc here.
for %%I in ("%~dp0..") do set "SOURCE_ROOT=%%~fI"
set "OUTPUT_ROOT=%SOURCE_ROOT%\artifacts\vc6"
set "VC6_ROOT=Z:\opt\vc"

if not exist "%SOURCE_ROOT%\krnln_VC6.dsw" (
  echo VC6 workspace not found: %SOURCE_ROOT%\krnln_VC6.dsw
  exit /b 2
)
if not exist "%VC6_ROOT%\BIN\MSDEV.EXE" (
  echo VC6 command-line builder not found: %VC6_ROOT%\BIN\MSDEV.EXE
  exit /b 2
)
if not exist "%VC6_ROOT%\INCLUDE" (
  echo VC6 include directory not found: %VC6_ROOT%\INCLUDE
  exit /b 2
)
if not exist "%VC6_ROOT%\LIB" (
  echo VC6 library directory not found: %VC6_ROOT%\LIB
  exit /b 2
)

if not exist "%OUTPUT_ROOT%" md "%OUTPUT_ROOT%"
if not exist "%OUTPUT_ROOT%\logs" md "%OUTPUT_ROOT%\logs"
del /q "%OUTPUT_ROOT%\krnln.lib" 2>nul
del /q "%OUTPUT_ROOT%\logs\krnln-vc6.log" 2>nul
if exist "%SOURCE_ROOT%\Release\krnln.lib" del /q "%SOURCE_ROOT%\Release\krnln.lib"
if exist "%SOURCE_ROOT%\Project\Release" rmdir /s /q "%SOURCE_ROOT%\Project\Release"

call "%VC6_ROOT%\setup.bat"
set "PATH=%VC6_ROOT%\BIN;%PATH%"
set "INCLUDE=%VC6_ROOT%\INCLUDE;%VC6_ROOT%\MFC\INCLUDE;%VC6_ROOT%\ATL\INCLUDE"
set "LIB=%VC6_ROOT%\LIB;%VC6_ROOT%\MFC\LIB"
chcp 936 >nul

echo Building krnln - Win32 Release with Visual C++ 6.0...
msdev.exe "%SOURCE_ROOT%\krnln_VC6.dsw" /MAKE "krnln - Win32 Release" /OUT "%OUTPUT_ROOT%\logs\krnln-vc6.log"
set "BUILD_EXIT=%ERRORLEVEL%"
if not "%BUILD_EXIT%"=="0" (
  echo VC6 core build failed with exit code %BUILD_EXIT%.
  exit /b %BUILD_EXIT%
)

if not exist "%SOURCE_ROOT%\Release\krnln.lib" (
  echo Expected VC6 release library was not produced: %SOURCE_ROOT%\Release\krnln.lib
  exit /b 3
)

copy /y "%SOURCE_ROOT%\Release\krnln.lib" "%OUTPUT_ROOT%\krnln.lib" >nul
echo VC6 core build completed: %OUTPUT_ROOT%\krnln.lib
exit /b 0
