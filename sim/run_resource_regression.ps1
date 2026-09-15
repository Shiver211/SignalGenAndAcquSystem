param(
    [string[]]$TestBenches = @(
        'tb_envelope_async_fifo_m7',
        'tb_signal_processing_m6',
        'tb_measurement_m6',
        'tb_control_plane_m3',
        'tb_capture_storage_m5',
        'tb_m7_raw_chunking',
        'tb_m7_envelope_chunking',
        'tb_m7_single_channel',
        'tb_m7_udp_stack'
    ),
    [string]$RunDirectory = (Join-Path $PSScriptRoot '..\tmp\fpga_resource_regression')
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$vivadoBin = Split-Path -Parent (Get-Command xvlog.bat -ErrorAction Stop).Source
$xpmRoot = Join-Path (Split-Path -Parent $vivadoBin) 'data\ip\xpm'
$runDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RunDirectory)
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

# 独立仿真目录，直接编译当前 RTL；不依赖工程中的旧仿真快照。
$compileProject = Join-Path $runDir 'sources.prj'
$compileLines = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'rtl') -Recurse -Filter '*.v' |
    Sort-Object FullName | ForEach-Object { 'verilog xil_defaultlib "{0}"' -f $_.FullName.Replace('\', '/') })
foreach ($testBench in $TestBenches) {
    $testPath = Join-Path $PSScriptRoot "$testBench.v"
    if (-not (Test-Path -LiteralPath $testPath)) { throw "仿真文件不存在：$testPath" }
    $compileLines += 'verilog xil_defaultlib "{0}"' -f $testPath.Replace('\', '/')
}
$memoryModel = Join-Path $PSScriptRoot 'ddr_native_model_m5.v'
$compileLines += 'verilog xil_defaultlib "{0}"' -f $memoryModel.Replace('\', '/')
$globalModel = Join-Path (Split-Path -Parent $vivadoBin) 'data\verilog\src\glbl.v'
$compileLines += 'verilog xil_defaultlib "{0}"' -f $globalModel.Replace('\', '/')
$compileLines += 'nosort'
Set-Content -LiteralPath $compileProject -Value $compileLines -Encoding ascii

function Invoke-SimTool {
    param([string]$ToolName, [string[]]$ToolArgs)
    $toolOutput = & (Join-Path $vivadoBin "$ToolName.bat") @ToolArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        $toolOutput | Select-Object -Last 50 | Write-Output
        throw "$ToolName 失败，退出码 $LASTEXITCODE"
    }
}

Push-Location $runDir
try {
    $xpmFiles = @(
        (Join-Path $xpmRoot 'xpm_cdc\hdl\xpm_cdc.sv'),
        (Join-Path $xpmRoot 'xpm_memory\hdl\xpm_memory.sv'),
        (Join-Path $xpmRoot 'xpm_fifo\hdl\xpm_fifo.sv')
    )
    Invoke-SimTool 'xvlog' (@('--sv', '--work', 'xpm') + $xpmFiles + @('-log', 'compile_xpm.log'))
    Invoke-SimTool 'xvlog' @('--relax', '-prj', $compileProject, '-log', 'compile_rtl.log')
    Write-Output '当前 RTL 和 XPM 编译完成。'

    foreach ($testBench in $TestBenches) {
        $snapshot = "${testBench}_resource"
        Invoke-SimTool 'xelab' @('--relax', '--mt', '2', '-L', 'xil_defaultlib',
            '-L', 'xpm', '-L', 'unisims_ver', '-L', 'unimacro_ver', '-L', 'secureip',
            '--snapshot', $snapshot, "xil_defaultlib.$testBench", 'xil_defaultlib.glbl',
            '-log', "${testBench}_elaborate.log")
        Invoke-SimTool 'xsim' @($snapshot, '-runall', '-log', "${testBench}_simulate.log")
        $simulationLog = Get-Content -LiteralPath "${testBench}_simulate.log" -Raw
        if ($simulationLog -notmatch 'SIM_PASS' -or
            $simulationLog -match 'SIM_FAIL|SIM_TIMEOUT|\[FAIL\]|Fatal:|Error:|ERROR:') {
            Get-Content -LiteralPath "${testBench}_simulate.log" -Tail 55 | Write-Output
            throw "$testBench 未通过。"
        }
        Write-Output "通过：$testBench"
    }
    if ($TestBenches -contains 'tb_signal_processing_m6') {
        & python -X utf8 (Join-Path $PSScriptRoot 'm6_reference.py') verify `
            (Join-Path $projectRoot 'tmp\m6_processing_results.csv')
        if ($LASTEXITCODE -ne 0) { throw '包络和测量结果未通过 Python 参考校验。' }
    }
    Write-Output "资源优化回归通过，共 $($TestBenches.Count) 项。日志：$runDir"
} finally {
    Pop-Location
}
