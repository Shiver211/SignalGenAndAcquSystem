[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$activeTools = @(Get-Process -Name vivado,xsim,xelab,xvlog -ErrorAction SilentlyContinue)
if ($activeTools.Count -gt 0) {
    throw '请先关闭正在运行的 Vivado 或仿真进程，再清理工作目录。'
}

function Remove-GeneratedItem {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    if (-not $resolvedPath.StartsWith($projectRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "清理目标超出工程目录：$resolvedPath"
    }
    $item = Get-Item -LiteralPath $resolvedPath -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "不清理符号链接或目录联接：$resolvedPath"
    }
    if ($PSCmdlet.ShouldProcess($resolvedPath, '清理可重新生成的文件')) {
        Remove-Item -LiteralPath $resolvedPath -Recurse -Force
        Write-Output "已清理：$resolvedPath"
    }
}

# 当前位流/检查点、IP 配置、数据库、参考资料及 artifacts 归档不在清理列表中。
foreach ($directory in @(
    'build', '.Xil', 'Signal.cache', 'Signal.gen', 'Signal.ip_user_files',
    'Signal.sim', 'Signal.srcs\utils_1', 'mcp_sim', 'xsim.dir'
)) {
    Remove-GeneratedItem (Join-Path $projectRoot $directory)
}

foreach ($sourceDirectory in @('host', 'scripts', 'sim')) {
    $caches = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot $sourceDirectory) -Directory -Recurse -Force |
        Where-Object Name -eq '__pycache__')
    foreach ($cache in $caches) { Remove-GeneratedItem $cache.FullName }
}

Get-ChildItem -LiteralPath $projectRoot -File -Force | Where-Object {
    $_.Name -match '^(vivado|xsim|xelab|xvlog).*[.](log|jou|pb)$' -or
    $_.Name -match '^hs_err_pid[0-9]+[.](log|dmp)$' -or
    $_.Name -eq 'dfx_runtime.txt'
} | ForEach-Object { Remove-GeneratedItem $_.FullName }
