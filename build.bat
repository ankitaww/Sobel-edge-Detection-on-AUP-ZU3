@echo off
REM ==========================================================================
REM build.bat - one-command build for a Windows laptop that has ONLY
REM Vivado + Vitis 2025.2 (no Python, git, make or WSL needed).
REM
REM   build.bat all                 csim, synth, cosim, export, bit, board
REM   build.bat csim                one step (several allowed: build.bat synth bit)
REM   build.bat --dry-run all       print every command instead of running it
REM
REM Logs:     results\logs\<step>.log   (also shown live on screen)
REM Results:  results\hls_summary.txt, results\vivado_summary.txt, results\*.rpt
REM Board:    results\sobel_board.zip   (upload to Jupyter on the board)
REM
REM Linux twin: build.sh. Machines with make + Python can still use the Makefile.
REM Only built-in Windows tools are used: cmd, PowerShell 5.1, and the Tcl
REM inside vitis-run / vivado.
REM TODO(verify-on-windows): tested on Windows 11 with stub vitis-run/vivado
REM only; the first real run on the build laptop is still to be done.
REM ==========================================================================
setlocal EnableExtensions DisableDelayedExpansion

REM ---- settings: edit here, or "set NAME=value" before calling build.bat ----
if not defined XILINX_VERSION   set "XILINX_VERSION=2025.2"
if not defined PART             set "PART=xczu3eg-sfvc784-2-e"
if not defined CLK_MHZ          set "CLK_MHZ=150"
REM Pixel limit per test sequence in RTL cosim (-1 = all; 1080p takes hours).
if not defined COSIM_MAX_PIXELS set "COSIM_MAX_PIXELS=20000"
REM Parallel Vivado synthesis/implementation jobs.
if not defined JOBS             set "JOBS=4"
REM Longer repo paths break Vivado/HLS on Windows (260-character path limit).
set "MAX_ROOT_LEN=40"
REM ---------------------------------------------------------------------------

REM Repo root = folder of this file, without the trailing backslash.
set "ROOT=%~dp0"
set "ROOT=%ROOT:~0,-1%"

REM ---- path check (before delayed expansion, so a '!' in the path is visible)
set "CHK=%ROOT: =%"
set "CHK=%CHK:(=%"
set "CHK=%CHK:)=%"
set "CHK=%CHK:!=%"
set "CHK=%CHK:&=%"
if not "%CHK%"=="%ROOT%" goto :err_path_chars

setlocal EnableDelayedExpansion
call :strlen ROOT ROOT_LEN
if %ROOT_LEN% GTR %MAX_ROOT_LEN% if not defined SOBEL_ALLOW_LONG_PATH goto :err_path_long

set "RESULTS=%ROOT%\results"
set "LOGDIR=%RESULTS%\logs"
set "HLS_DIR=%ROOT%\hls\sobel_otsu"
set "OVERLAY=%ROOT%\pynq\overlay"
set "PSH=powershell -NoProfile -ExecutionPolicy Bypass"
cd /d "%ROOT%"

REM ---- arguments --------------------------------------------------------------
set "DRY=0"
set "STEPS="
for %%A in (%*) do (
    if /i "%%~A"=="--dry-run" (
        set "DRY=1"
    ) else if /i "%%~A"=="all" (
        set "STEPS=!STEPS! csim synth cosim export bit board"
    ) else (
        set "STEPS=!STEPS! %%~A"
    )
)
if not defined STEPS goto :usage
for %%S in (%STEPS%) do (
    set "KNOWN=0"
    for %%V in (csim synth cosim export bit board) do if /i "%%S"=="%%V" set "KNOWN=1"
    if "!KNOWN!"=="0" (
        echo ERROR: unknown step "%%S"
        echo.
        goto :usage
    )
)

REM Which tools do the requested steps need?
set "NEED_HLS=0"
set "NEED_VIVADO=0"
for %%S in (%STEPS%) do (
    for %%V in (csim synth cosim export) do if /i "%%S"=="%%V" set "NEED_HLS=1"
    if /i "%%S"=="bit" set "NEED_VIVADO=1"
)

echo == repo      : %ROOT%
echo == steps     :%STEPS%
echo == settings  : PART=%PART% CLK_MHZ=%CLK_MHZ% COSIM_MAX_PIXELS=%COSIM_MAX_PIXELS% JOBS=%JOBS%
if "%DRY%"=="1" echo == DRY RUN: commands are printed, not run.

REM ---- test vectors (committed in git; the build laptop has no Python) -------
if "%NEED_HLS%"=="1" if not exist "%ROOT%\hls\tb_data\cases.txt" goto :err_vectors

REM ---- find Vivado / Vitis ------------------------------------------------------
set "NEED_TOOLS=0"
if "%NEED_HLS%"=="1" set "NEED_TOOLS=1"
if "%NEED_VIVADO%"=="1" set "NEED_TOOLS=1"
if "%NEED_TOOLS%"=="0" goto :tools_ok
call :find_tools
if errorlevel 1 if "%DRY%"=="0" exit /b 1
:tools_ok

if not exist "%LOGDIR%" mkdir "%LOGDIR%"

REM ---- run the steps; stop at the first failure ----------------------------------
set "FAILED="
for %%S in (%STEPS%) do (
    if not defined FAILED (
        call :run_step %%S
        if errorlevel 1 set "FAILED=%%S"
    )
)

REM ---- final table ------------------------------------------------------------------
echo.
echo ======================== build summary ========================
for %%S in (%STEPS%) do (
    set "ST=!ST_%%S!"
    if not defined ST set "ST=not run"
    set "TM="
    if defined TM_%%S call :fmt_time !TM_%%S! TM
    set "COL=%%S          "
    set "COL2=!ST!                "
    echo   !COL:~0,8!  !COL2:~0,14!  !TM!
)
echo ===============================================================
if defined WARN_II (
    echo WARNING: the HLS pixel loop II is not 1 - see results\hls_summary.txt
)
if defined FAILED (
    echo RESULT: FAIL at step %FAILED%   - log: results\logs\%FAILED%.log
    exit /b 1
)
if "%DRY%"=="1" (
    echo RESULT: dry run finished - nothing was built
    exit /b 0
)
echo RESULT: PASS
if exist "%RESULTS%\hls_summary.txt" echo   HLS summary   : results\hls_summary.txt
if exist "%RESULTS%\vivado_summary.txt" echo   Vivado summary: results\vivado_summary.txt
exit /b 0


REM ================================================================== subroutines

:run_step
REM %1 = step name. Runs :step_<name>, times it, records ST_<name> / TM_<name>.
set "S=%~1"
set "STEP_LOG=%LOGDIR%\%S%.log"
REM A fresh log per run, so a failure never shows lines from an older run.
if "%DRY%"=="0" if exist "%STEP_LOG%" del /q "%STEP_LOG%"
call :now T0
echo.
echo ===============================================================
echo == step %S%    log: results\logs\%S%.log
echo ===============================================================
call :step_%S%
set "RC=%ERRORLEVEL%"
call :now T1
set /a "DT=T1-T0"
if %DT% LSS 0 set /a "DT+=86400"
set "TM_%S%=%DT%"
set "ST_%S%=PASS"
if "%DRY%"=="1" set "ST_%S%=dry-run"
if not "%RC%"=="0" set "ST_%S%=FAIL"
call :fmt_time %DT% DTS
echo == step %S%: !ST_%S%!  (%DTS%)
if not "%RC%"=="0" call :show_failure %S%
exit /b %RC%

REM ---- HLS steps. run_hls.tcl does the work; HLS_STEP selects what it runs.
REM Each run starts a fresh component (open_component -reset), so synth, cosim
REM and export each re-run csynth_design. Slower, but every step stands alone.
:step_csim
set "HLS_STEP=csim"
call :tool "%HLS_DIR%" "vitis-run --mode hls --tcl run_hls.tcl"
if errorlevel 1 exit /b 1
call :need_tb_pass
exit /b %ERRORLEVEL%

:step_synth
set "HLS_STEP=synth"
if "%DRY%"=="0" if exist "%RESULTS%\hls_summary.txt" del /q "%RESULTS%\hls_summary.txt"
call :tool "%HLS_DIR%" "vitis-run --mode hls --tcl run_hls.tcl"
if errorlevel 1 exit /b 1
call :check_hls_summary
exit /b 0

:step_cosim
set "HLS_STEP=cosim"
call :tool "%HLS_DIR%" "vitis-run --mode hls --tcl run_hls.tcl"
if errorlevel 1 exit /b 1
call :need_tb_pass
exit /b %ERRORLEVEL%

:step_export
set "HLS_STEP=export"
if "%DRY%"=="0" if exist "%HLS_DIR%\export\sobel_otsu.zip" del /q "%HLS_DIR%\export\sobel_otsu.zip"
call :tool "%HLS_DIR%" "vitis-run --mode hls --tcl run_hls.tcl"
if errorlevel 1 exit /b 1
if "%DRY%"=="1" exit /b 0
if exist "%HLS_DIR%\export\sobel_otsu.zip" exit /b 0
REM TODO(verify-in-vitis): 2025.2 may leave only an unpacked IP (component.xml).
dir /s /b "%HLS_DIR%\sobel_otsu_hls\component.xml" >nul 2>&1
if not errorlevel 1 exit /b 0
echo ERROR: export finished but neither hls\sobel_otsu\export\sobel_otsu.zip
echo        nor a component.xml under hls\sobel_otsu\sobel_otsu_hls was found.
exit /b 1

REM ---- Vivado: block design + bitstream -> pynq\overlay\sobel_otsu.{bit,hwh}
:step_bit
if "%DRY%"=="0" if not exist "%ROOT%\vivado\build" mkdir "%ROOT%\vivado\build"
REM Delete the old overlay so a stale .bit can never look like a fresh one.
if "%DRY%"=="0" if exist "%OVERLAY%\sobel_otsu.bit" del /q "%OVERLAY%\sobel_otsu.bit"
if "%DRY%"=="0" if exist "%OVERLAY%\sobel_otsu.hwh" del /q "%OVERLAY%\sobel_otsu.hwh"
call :tool "%ROOT%\vivado\build" "vivado -mode batch -source ..\create_project.tcl -nojournal -log vivado.log"
if errorlevel 1 exit /b 1
if "%DRY%"=="1" exit /b 0
if not exist "%OVERLAY%\sobel_otsu.bit" goto :bit_missing
if not exist "%OVERLAY%\sobel_otsu.hwh" goto :bit_missing
echo == overlay: pynq\overlay\sobel_otsu.bit + sobel_otsu.hwh
exit /b 0
:bit_missing
echo ERROR: Vivado finished but pynq\overlay\sobel_otsu.bit / .hwh are missing.
exit /b 1

REM ---- board: results\sobel_board.zip for the PYNQ Jupyter upload
:step_board
if "%DRY%"=="1" goto :board_zip
if exist "%RESULTS%\sobel_board.zip" del /q "%RESULTS%\sobel_board.zip"
if not exist "%OVERLAY%\sobel_otsu.bit" goto :board_no_bit
if not exist "%OVERLAY%\sobel_otsu.hwh" goto :board_no_bit
:board_zip
call :tool "%ROOT%" "%PSH% -File scripts\make_board_zip.ps1 %ROOT% %RESULTS%\sobel_board.zip"
if errorlevel 1 exit /b 1
echo.
echo ---------------- on the board (PYNQ v3.1, USB-C cable) ----------------
echo  1. Open http://192.168.3.1:9090 in a browser (password: xilinx).
echo  2. In the top folder click Upload, pick results\sobel_board.zip, click Upload.
echo  3. New - Terminal, then:   cd /home/xilinx/jupyter_notebooks
echo                             unzip -o sobel_board.zip
echo     (no unzip? use: python3 -m zipfile -e sobel_board.zip .)
echo  4. Open the folder sobel/notebooks, New - Python 3 notebook, run a cell:
echo         %%run 01_bringup.py
echo     It must print PASS.
echo ------------------------------------------------------------------------
exit /b 0
:board_no_bit
echo ERROR: pynq\overlay\sobel_otsu.bit or sobel_otsu.hwh is missing.
echo        Build the overlay first:   build.bat bit    (or: build.bat all)
exit /b 1

REM ---- helpers ----------------------------------------------------------------

:tool
REM %1 = working directory, %2 = command line. Output goes to the screen and to
REM %STEP_LOG% (run_logged.ps1). Returns the command's exit code.
set "STEP_CMD=%~2"
if "%DRY%"=="1" goto :tool_dry
pushd "%~1"
if errorlevel 1 exit /b 1
%PSH% -File "%ROOT%\scripts\run_logged.ps1"
set "TOOL_RC=%ERRORLEVEL%"
popd
exit /b %TOOL_RC%
:tool_dry
echo [dry-run] cd /d %~1
echo [dry-run] %STEP_CMD%   (output -^> %STEP_LOG%)
exit /b 0

:need_tb_pass
REM The testbench must have printed "RESULT         : PASS" (exit codes alone
REM are not trusted). Fallback: the HLS tool's own logs.
if "%DRY%"=="1" exit /b 0
findstr /C:"RESULT         : PASS" "%STEP_LOG%" >nul 2>&1
if not errorlevel 1 exit /b 0
REM TODO(verify-on-windows): is the testbench output echoed to the console in
REM 2025.2? If not, it is in the component's csim/cosim logs:
for /r "%HLS_DIR%\sobel_otsu_hls" %%F in (*.log) do (
    findstr /C:"RESULT         : PASS" "%%F" >nul 2>&1
    if not errorlevel 1 (
        echo == testbench PASS line found in %%F
        exit /b 0
    )
)
echo ERROR: the tool finished, but the testbench line "RESULT         : PASS"
echo        was not found in results\logs\%S%.log or in the HLS logs.
exit /b 1

:check_hls_summary
if "%DRY%"=="1" exit /b 0
if not exist "%RESULTS%\hls_summary.txt" (
    echo WARNING: results\hls_summary.txt was not written - read the csynth report by hand.
    exit /b 0
)
findstr /C:"WARNING: PIXEL LOOP II" "%RESULTS%\hls_summary.txt" >nul 2>&1
if not errorlevel 1 set "WARN_II=1"
exit /b 0

:find_tools
REM Tools already on PATH (settings64 run by hand)? Then nothing to do.
call :have_tools quiet
if not errorlevel 1 (
    echo == Vivado/Vitis already on PATH
    exit /b 0
)
set "XR="
if defined XILINX_ROOT set "XR=%XILINX_ROOT%"
if not defined XR if exist "C:\Xilinx\%XILINX_VERSION%\Vivado" set "XR=C:\Xilinx\%XILINX_VERSION%"
if not defined XR if exist "C:\AMDDesignTools\%XILINX_VERSION%\Vivado" set "XR=C:\AMDDesignTools\%XILINX_VERSION%"
if not defined XR goto :tools_missing
echo == Xilinx install: %XR%
REM vitis-run / vivado / settings64 are batch files: always "call" them, or
REM this script would never get control back.
REM TODO(verify-on-windows): settings64.bat names/locations in the 2025.2 Windows install.
if "%DRY%"=="1" (
    echo [dry-run] call "%XR%\Vitis\settings64.bat"
    echo [dry-run] call "%XR%\Vivado\settings64.bat"
    exit /b 0
)
if exist "%XR%\Vitis\settings64.bat" call "%XR%\Vitis\settings64.bat"
if exist "%XR%\Vivado\settings64.bat" call "%XR%\Vivado\settings64.bat"
cd /d "%ROOT%"
REM Fallback if a settings64.bat is missing: put the bin folders on PATH.
where vitis-run >nul 2>&1
if errorlevel 1 if exist "%XR%\Vitis\bin\vitis-run.bat" set "PATH=%XR%\Vitis\bin;!PATH!"
where vivado >nul 2>&1
if errorlevel 1 if exist "%XR%\Vivado\bin\vivado.bat" set "PATH=%XR%\Vivado\bin;!PATH!"
call :have_tools
if errorlevel 1 goto :tools_missing
exit /b 0

:have_tools
REM errorlevel 0 if every tool the requested steps need is on PATH.
set "MISSING="
if "%NEED_HLS%"=="1" (
    where vitis-run >nul 2>&1
    if errorlevel 1 set "MISSING=!MISSING! vitis-run"
)
if "%NEED_VIVADO%"=="1" (
    where vivado >nul 2>&1
    if errorlevel 1 set "MISSING=!MISSING! vivado"
)
if not defined MISSING exit /b 0
if not "%~1"=="quiet" echo ERROR: not found on PATH:%MISSING%
exit /b 1

:tools_missing
echo.
echo ERROR: Vivado/Vitis %XILINX_VERSION% not found.
echo        Tell build.bat where they are installed, e.g.
echo            set XILINX_ROOT=C:\Xilinx\%XILINX_VERSION%
echo        (the folder that contains Vivado\ and Vitis\), then run build.bat again.
echo        Searched: %%XILINX_ROOT%%, C:\Xilinx\%XILINX_VERSION%, C:\AMDDesignTools\%XILINX_VERSION%
exit /b 1

:show_failure
echo.
echo ***************************************************************
echo FAILED at step %~1
echo ***************************************************************
if not exist "%STEP_LOG%" exit /b 0
echo Last 40 lines of results\logs\%~1.log:
echo ---------------------------------------------------------------
%PSH% -Command "Get-Content -Tail 40 -LiteralPath $env:STEP_LOG"
echo ---------------------------------------------------------------
exit /b 0

:now
REM %1 = variable to receive seconds since midnight (locale-safe enough:
REM handles a leading space and "08"/"09" which set /a would read as octal).
set "NOW=%TIME: =0%"
for /f "tokens=1-3 delims=:.," %%a in ("%NOW%") do set /a "%~1=(1%%a-100)*3600+(1%%b-100)*60+(1%%c-100)"
exit /b 0

:fmt_time
REM %1 = seconds, %2 = variable to receive "Hh MMm SSs"
set /a "FT_H=%~1/3600, FT_M=(%~1%%3600)/60, FT_S=%~1%%60"
set "FT_M=0%FT_M%"
set "FT_S=0%FT_S%"
set "%~2=%FT_H%h %FT_M:~-2%m %FT_S:~-2%s"
exit /b 0

:strlen
REM %1 = variable name, %2 = variable to receive its length
set "SL=!%~1!#"
set "SL_LEN=0"
for %%P in (4096 2048 1024 512 256 128 64 32 16 8 4 2 1) do (
    if not "!SL:~%%P,1!"=="" (
        set /a "SL_LEN+=%%P"
        set "SL=!SL:~%%P!"
    )
)
set "%~2=%SL_LEN%"
exit /b 0

REM ---- error exits ----------------------------------------------------------------

:usage
echo Usage:  build.bat [--dry-run] STEP [STEP ...]
echo.
echo   csim     HLS C simulation against the golden vectors (must print PASS)
echo   synth    HLS synthesis  -^> results\hls_summary.txt (pixel loop II, clock, resources)
echo   cosim    HLS C/RTL co-simulation (COSIM_MAX_PIXELS=%COSIM_MAX_PIXELS%)
echo   export   HLS IP export for Vivado
echo   bit      Vivado bitstream -^> pynq\overlay\sobel_otsu.bit/.hwh, results\vivado_summary.txt
echo   board    pack results\sobel_board.zip for the PYNQ board
echo   all      csim synth cosim export bit board
echo.
echo   --dry-run  print the commands instead of running them
echo.
echo Settings (set before calling, e.g. "set CLK_MHZ=125"):
echo   XILINX_ROOT  CLK_MHZ  PART  COSIM_MAX_PIXELS  JOBS
exit /b 1

:err_path_chars
echo ERROR: the repo path contains a space or one of ( ) and other special characters:
echo            "%ROOT%"
echo        Vivado/Vitis and this script need a plain path. Move the folder to
echo            C:\sobel
echo        and run C:\sobel\build.bat again.
exit /b 1

:err_path_long
echo ERROR: the repo path is %ROOT_LEN% characters long (limit %MAX_ROOT_LEN%):
echo            %ROOT%
echo        Vivado/Vitis builds deep folders and hit the Windows 260-character
echo        path limit. Move the folder to
echo            C:\sobel
echo        and run C:\sobel\build.bat again.
echo        (To try anyway: set SOBEL_ALLOW_LONG_PATH=1)
exit /b 1

:err_vectors
echo ERROR: hls\tb_data\cases.txt is missing. The test vectors are part of the
echo        repo download; extract the whole ZIP again (do not skip hls\tb_data).
exit /b 1
