param(
    [string]$VivadoCommand = "vivado.bat",
    [switch]$SkipProgram,
    [Alias("BurnOnly")]
    [switch]$ProgramOnly
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $PSCommandPath
$projectRoot = Split-Path -Parent (Split-Path -Parent $scriptRoot)
$buildScript = Join-Path $scriptRoot "run_build.tcl"
$prepareIpScript = Join-Path $scriptRoot "prepare_ip.ps1"
$programScript = Join-Path $scriptRoot "program_hw.tcl"
$bitstream = Join-Path $projectRoot "Signal.runs\impl_1\Top.bit"
$runDirectory = Join-Path $projectRoot "build\vivado"

if ($SkipProgram -and $ProgramOnly) {
    throw "-SkipProgram and -ProgramOnly cannot be used together"
}

if (-not $ProgramOnly -and -not (Test-Path -LiteralPath $buildScript)) {
    throw "Build script not found: $buildScript"
}
if (-not (Test-Path -LiteralPath $programScript)) {
    throw "Program script not found: $programScript"
}

$vivado = Get-Command $VivadoCommand -ErrorAction SilentlyContinue
if (-not $vivado) {
    throw "Vivado not found: $VivadoCommand. Add Vivado\bin to PATH or pass -VivadoCommand with the full path to vivado.bat."
}

New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
Push-Location $runDirectory
try {
    if (-not $ProgramOnly) {
        & $prepareIpScript -VivadoCommand $vivado.Source -ProjectRoot $projectRoot
        Write-Host "=== Build FPGA (synthesis, implementation, bitstream) ===" -ForegroundColor Cyan
        & $vivado.Source -mode batch -source $buildScript -log build.log -journal build.jou
        if ($LASTEXITCODE -ne 0) {
            throw "FPGA build failed, exit code: $LASTEXITCODE"
        }

        if (-not (Test-Path -LiteralPath $bitstream)) {
            throw "Build completed but bitstream was not found: $bitstream"
        }
    } elseif (-not (Test-Path -LiteralPath $bitstream)) {
        throw "Program-only mode requires an existing bitstream: $bitstream"
    }

    if ($ProgramOnly -or -not $SkipProgram) {
        Write-Host "=== Program FPGA ===" -ForegroundColor Cyan
        & $vivado.Source -mode batch -source $programScript -log program.log -journal program.jou
        if ($LASTEXITCODE -ne 0) {
            throw "FPGA programming failed, exit code: $LASTEXITCODE"
        }
    }

    Write-Host "=== Done ===" -ForegroundColor Green
    if ($ProgramOnly) {
        Write-Host "Programmed: $bitstream"
    } elseif ($SkipProgram) {
        Write-Host "Generated: $bitstream"
    } else {
        Write-Host "Built and programmed: $bitstream"
    }
} finally {
    Pop-Location
}
