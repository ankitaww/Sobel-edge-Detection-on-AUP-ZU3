# run_logged.ps1: run one build command, show its output live AND save it to a log.
# Used by build.bat (Windows PowerShell 5.1, nothing to install).
#
# Inputs come through environment variables so cmd.exe never has to quote them:
#   STEP_CMD   command line to run with cmd.exe (e.g. "vitis-run --mode hls --tcl run_hls.tcl")
#   STEP_LOG   log file to write (overwritten)
# The working directory is inherited from build.bat (pushd).
# Exit code = the command's exit code.
#
# Why not Tee-Object: in PowerShell 5.1 it writes UTF-16, which findstr cannot
# search. This writes plain UTF-8 without BOM.
# TODO(verify-on-windows): run once on the build laptop.

$cmd = $env:STEP_CMD
$log = $env:STEP_LOG
if (-not $cmd -or -not $log) {
    Write-Host "run_logged.ps1: STEP_CMD and STEP_LOG must be set"
    exit 2
}

$enc = New-Object System.Text.UTF8Encoding($false)
$writer = New-Object System.IO.StreamWriter($log, $false, $enc)
$writer.AutoFlush = $true
$rc = 1
try {
    # 2>&1 inside cmd.exe: PowerShell only sees stdout, so stderr lines are not
    # turned into PowerShell error records (a PS 5.1 pitfall).
    & cmd.exe /d /c "$cmd 2>&1" | ForEach-Object {
        $line = [string]$_
        $writer.WriteLine($line)
        Write-Host $line
    }
    $rc = $LASTEXITCODE
} finally {
    $writer.Close()
}
if ($null -eq $rc) { $rc = 1 }
exit $rc
