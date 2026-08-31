@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem This script runs only inside the pinned giulioz/vc6-docker probe image.
rem MSDEV.EXE cannot start there because the image omits its MFC runtime, so
rem build the same VC6 DSP source set with its CL.EXE and LIB.EXE tools.
for %%I in ("%~dp0..") do set "SOURCE_ROOT=%%~fI"
set "OUTPUT_ROOT=%SOURCE_ROOT%\artifacts\vc6"
set "OBJECT_ROOT=%OUTPUT_ROOT%\obj"
set "SOURCE_LIST=%OUTPUT_ROOT%\sources.lst"
set "RESPONSE_FILE=%OUTPUT_ROOT%\krnln-vc6.rsp"
set "LOG_PATH=%OUTPUT_ROOT%\logs\krnln-vc6.log"
set "VC6_ROOT=Z:\opt\vc"
set "EXPECTED_OBJECT_COUNT=237"

if not exist "%SOURCE_ROOT%\krnln_VC6.dsw" (
  echo VC6 workspace not found: %SOURCE_ROOT%\krnln_VC6.dsw
  exit /b 2
)
if not exist "%SOURCE_LIST%" (
  echo VC6 source list not found: %SOURCE_LIST%
  exit /b 2
)
if not exist "%VC6_ROOT%\BIN\CL.EXE" (
  echo VC6 compiler not found: %VC6_ROOT%\BIN\CL.EXE
  exit /b 2
)
if not exist "%VC6_ROOT%\BIN\LIB.EXE" (
  echo VC6 librarian not found: %VC6_ROOT%\BIN\LIB.EXE
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

if exist "%OBJECT_ROOT%" rmdir /s /q "%OBJECT_ROOT%"
if not exist "%OUTPUT_ROOT%" md "%OUTPUT_ROOT%"
if not exist "%OUTPUT_ROOT%\logs" md "%OUTPUT_ROOT%\logs"
md "%OBJECT_ROOT%"
del /q "%OUTPUT_ROOT%\krnln.lib" 2>nul
del /q "%RESPONSE_FILE%" 2>nul
del /q "%LOG_PATH%" 2>nul

call "%VC6_ROOT%\setup.bat"
set "PATH=%VC6_ROOT%\BIN;%PATH%"
set "INCLUDE=%VC6_ROOT%\INCLUDE"
set "LIB=%VC6_ROOT%\LIB"
set "COMMON_FLAGS=/nologo /MT /W3 /GX /O2 /D WIN32 /D NDEBUG /D _WINDOWS /D _MBCS /FD /c"
set /a COMPILED_SOURCE_COUNT=0

> "%RESPONSE_FILE%" echo /nologo
>> "%RESPONSE_FILE%" echo /out:"%OUTPUT_ROOT%\krnln.lib"

echo Building krnln - Win32 Release with VC6 CL.EXE and LIB.EXE...
call :CompileSource "%SOURCE_ROOT%\krnln\StdAfx.cpp" /Ycstdafx.h
if errorlevel 1 goto :build_failed

for /f "usebackq delims=" %%S in ("%SOURCE_LIST%") do (
  set "RELATIVE_SOURCE=%%S"
  if /I not "!RELATIVE_SOURCE!"=="..\krnln\StdAfx.cpp" (
    for %%I in ("%SOURCE_ROOT%\Project\!RELATIVE_SOURCE!") do set "SOURCE_FILE=%%~fI"
    call :CompileSource "!SOURCE_FILE!" /Yustdafx.h
    if errorlevel 1 goto :build_failed
  )
)

if not "%COMPILED_SOURCE_COUNT%"=="%EXPECTED_OBJECT_COUNT%" (
  echo Expected %EXPECTED_OBJECT_COUNT% VC6 source compilations, got %COMPILED_SOURCE_COUNT%.
  set "BUILD_EXIT=3"
  goto :build_failed
)
set /a OBJECT_FILE_COUNT=0
for %%I in ("%OBJECT_ROOT%\*.obj") do set /a OBJECT_FILE_COUNT+=1
if not "%OBJECT_FILE_COUNT%"=="%EXPECTED_OBJECT_COUNT%" (
  echo Expected %EXPECTED_OBJECT_COUNT% VC6 object files, got %OBJECT_FILE_COUNT%.
  set "BUILD_EXIT=3"
  goto :build_failed
)

if not exist "%SOURCE_ROOT%\krnln\Diskid32.obj" (
  echo Required VC6 object not found: %SOURCE_ROOT%\krnln\Diskid32.obj
  set "BUILD_EXIT=3"
  goto :build_failed
)
if not exist "%SOURCE_ROOT%\krnln\PY.OBJ" (
  echo Required VC6 object not found: %SOURCE_ROOT%\krnln\PY.OBJ
  set "BUILD_EXIT=3"
  goto :build_failed
)
>> "%RESPONSE_FILE%" echo "%SOURCE_ROOT%\krnln\Diskid32.obj"
>> "%RESPONSE_FILE%" echo "%SOURCE_ROOT%\krnln\PY.OBJ"

lib.exe @"%RESPONSE_FILE%" >> "%LOG_PATH%" 2>&1
if errorlevel 1 goto :build_failed
if not exist "%OUTPUT_ROOT%\krnln.lib" (
  echo Expected VC6 release library was not produced: %OUTPUT_ROOT%\krnln.lib
  set "BUILD_EXIT=3"
  goto :build_failed
)

echo VC6 core build completed: %OUTPUT_ROOT%\krnln.lib
exit /b 0

:CompileSource
set "PCH_FLAG=%~2"
echo [VC6] %~nx1
cl.exe %COMMON_FLAGS% %PCH_FLAG% /Fp"%OBJECT_ROOT%\krnln.pch" /Fo"%OBJECT_ROOT%\%~n1.obj" "%~f1" >> "%LOG_PATH%" 2>&1
if errorlevel 1 exit /b 1
>> "%RESPONSE_FILE%" echo "%OBJECT_ROOT%\%~n1.obj"
set /a COMPILED_SOURCE_COUNT+=1
exit /b 0

:build_failed
if not defined BUILD_EXIT set "BUILD_EXIT=%ERRORLEVEL%"
if "%BUILD_EXIT%"=="0" set "BUILD_EXIT=1"
echo VC6 core build failed with exit code %BUILD_EXIT%. See %LOG_PATH%.
if exist "%LOG_PATH%" type "%LOG_PATH%"
exit /b %BUILD_EXIT%
