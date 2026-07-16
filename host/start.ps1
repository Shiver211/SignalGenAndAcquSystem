$ErrorActionPreference = "Stop"
$HostRoot = Split-Path -Parent $PSCommandPath
$RepoRoot = Split-Path -Parent $HostRoot
$Address = "192.168.1.100"
$PrimaryAddress = "49.140.66.33"
$FirewallRuleName = "FPGA Signal System UDP 5001"

$interface = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $PrimaryAddress -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $interface) {
    $interface = Get-NetAdapter -Physical |
        Where-Object { $_.Status -eq "Up" -and $_.InterfaceDescription -notmatch "Wireless|Wi-Fi" } |
        Select-Object -First 1
}
if (-not $interface) {
    throw "No connected Ethernet adapter was found"
}

$interfaceIndex = if ($interface.InterfaceIndex) { $interface.InterfaceIndex } else { $interface.ifIndex }
$configured = Get-NetIPAddress `
    -InterfaceIndex $interfaceIndex `
    -IPAddress $Address `
    -ErrorAction SilentlyContinue
$firewallConfigured = Get-NetFirewallRule `
    -DisplayName $FirewallRuleName `
    -ErrorAction SilentlyContinue

if (-not $configured -or -not $firewallConfigured) {
    $setupScript = Join-Path $HostRoot "setup_network.ps1"
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$setupScript`" -InterfaceIndex $interfaceIndex"
    $process = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList $arguments
    if ($process.ExitCode -ne 0) {
        $errorLog = Join-Path $env:TEMP "signal_setup_network_error.log"
        $detail = if (Test-Path $errorLog) { Get-Content -Raw $errorLog } else { "Unknown error" }
        throw "Failed to configure $Address/24: $detail"
    }
}

$python = (Get-Command python -ErrorAction Stop).Source
$pythonw = Join-Path (Split-Path -Parent $python) "pythonw.exe"
if (-not (Test-Path $pythonw)) {
    $pythonw = $python
}

Start-Process `
    -FilePath $pythonw `
    -ArgumentList "`"$(Join-Path $HostRoot 'main.py')`"" `
    -WorkingDirectory $RepoRoot
