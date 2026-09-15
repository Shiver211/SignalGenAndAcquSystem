param(
    [string]$VivadoCommand = 'vivado.bat',
    [string]$ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

$ErrorActionPreference = 'Stop'
$projectDirectory = (Resolve-Path -LiteralPath $ProjectRoot).Path
$projectXml = [xml](Get-Content -LiteralPath (Join-Path $projectDirectory 'Signal.xpr') -Raw)
$part = $projectXml.SelectSingleNode('//Option[@Name="Part"]').Val
$ipFiles = @($projectXml.SelectNodes('//File[@Path]') |
    Where-Object { [IO.Path]::GetExtension($_.Path) -eq '.xci' } |
    ForEach-Object { [IO.Path]::GetFullPath($_.Path.Replace('$PPRDIR', $projectDirectory)) } |
    Select-Object -Unique)
$vivado = (Get-Command $VivadoCommand -ErrorAction Stop).Source
$prepareScript = Join-Path $PSScriptRoot 'prepare_ip.tcl'
$runDirectory = Join-Path $projectDirectory 'build\vivado'
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null

Push-Location -LiteralPath $runDirectory
try {
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $logPath = Join-Path $runDirectory "prepare_ip_$attempt.log"
        $consolePath = Join-Path $runDirectory "prepare_ip_${attempt}_console.log"
        # Windows PowerShell 5 会把工具的标准错误转成异常；先等进程退出，
        # 再统一按退出码处理，确保 MIG 占用的目录已经释放。
        $savedErrorAction = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $vivado -mode batch -notrace -nojournal -source $prepareScript -log $logPath `
                -tclargs $part @ipFiles *> $consolePath
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedErrorAction
        }
        if ($exitCode -eq 0) {
            Write-Output "IP 输出产品已就绪，共 $($ipFiles.Count) 个。日志：$logPath"
            return
        }

        # Vivado 2025.2 Windows 的 MIG 首次生成会占用 _tmp 中的目录，
        # 导致自身 file rename 失败。仅在生成器明确返回成功时恢复输出。
        $logText = Get-Content -LiteralPath $logPath -Raw
        $migXci = $ipFiles | Where-Object { [IO.Path]::GetFileName($_) -eq 'ddr3_mig_m4.xci' }
        $migDirectory = Split-Path -Parent $migXci
        $temporaryDirectory = Join-Path $migDirectory '_tmp'
        $generatorResult = Join-Path $migDirectory 'xil_txt.out'
        if ($attempt -eq 2 -or $logText -notmatch 'error renaming .*[/\\]_tmp[/\\].*: permission denied' -or
            -not (Test-Path -LiteralPath $generatorResult) -or
            (Get-Content -LiteralPath $generatorResult -Raw) -notmatch '(?m)^SET_ERROR_CODE 0\s*$') {
            throw "IP 输出产品生成失败，退出码 $exitCode。详见：$logPath"
        }

        foreach ($generatedItem in @(Get-ChildItem -LiteralPath $temporaryDirectory -Force)) {
            $sourcePath = (Resolve-Path -LiteralPath $generatedItem.FullName).Path
            $targetPath = [IO.Path]::GetFullPath((Join-Path $migDirectory $generatedItem.Name))
            if (-not $sourcePath.StartsWith($projectDirectory + '\', [StringComparison]::OrdinalIgnoreCase) -or
                -not $targetPath.StartsWith($projectDirectory + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw "MIG 输出路径超出工程目录：$sourcePath -> $targetPath"
            }
            Move-Item -LiteralPath $sourcePath -Destination $targetPath -Force
        }

        # MIG 按文本行比较输入与生成目录内的 mig.prj。保存本次实际输入，
        # 避免生成器改写注释/空白后反复生成；原始 PRJ 和生成的 RTL 均不改动。
        $migConfig = Get-Content -LiteralPath $migXci -Raw | ConvertFrom-Json
        $prjRelativePath = $migConfig.ip_inst.parameters.component_parameters.XML_INPUT_FILE[0].value
        Copy-Item -LiteralPath (Join-Path $migDirectory $prjRelativePath) `
            -Destination (Join-Path $migDirectory 'ddr3_mig_m4\mig.prj') -Force
        Write-Output 'MIG 临时输出已恢复，重新载入并验证全部 IP。'
    }
} finally {
    Pop-Location
}
