param(
    [Parameter(Mandatory = $true)]
    [int]$InterfaceIndex
)

$ErrorActionPreference = "Stop"
$Address = "192.168.1.100"
$FpgaAddress = "192.168.1.10"
$UdpPort = 5001
$FirewallRuleName = "FPGA Signal System UDP 5001"
$ErrorLog = Join-Path $env:TEMP "signal_setup_network_error.log"

trap {
    ($_ | Out-String) | Set-Content -Path $ErrorLog -Encoding UTF8
    exit 1
}

$active = Get-NetIPAddress `
    -InterfaceIndex $InterfaceIndex `
    -IPAddress $Address `
    -PolicyStore ActiveStore `
    -ErrorAction SilentlyContinue
$persistent = Get-NetIPAddress `
    -InterfaceIndex $InterfaceIndex `
    -IPAddress $Address `
    -PolicyStore PersistentStore `
    -ErrorAction SilentlyContinue

$adapter = Get-NetAdapter | Where-Object { $_.ifIndex -eq $InterfaceIndex } | Select-Object -First 1
if (-not $adapter) {
    throw "Network adapter index $InterfaceIndex does not exist"
}
if ($adapter.Status -ne "Up") {
    throw "Network adapter index $InterfaceIndex is not connected"
}

if (-not $active -or -not $persistent) {
    New-NetIPAddress `
        -InterfaceIndex $InterfaceIndex `
        -IPAddress $Address `
        -PrefixLength 24 `
        -AddressFamily IPv4 | Out-Null
}

if (-not (Get-NetIPAddress -InterfaceIndex $InterfaceIndex -IPAddress $Address -PolicyStore ActiveStore -ErrorAction SilentlyContinue)) {
    throw "The address was not written to ActiveStore"
}
if (-not (Get-NetIPAddress -InterfaceIndex $InterfaceIndex -IPAddress $Address -PolicyStore PersistentStore -ErrorAction SilentlyContinue)) {
    throw "The address was not written to PersistentStore"
}

if (-not (Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule `
        -DisplayName $FirewallRuleName `
        -Direction Inbound `
        -Action Allow `
        -Protocol UDP `
        -LocalAddress $Address `
        -LocalPort $UdpPort `
        -RemoteAddress $FpgaAddress `
        -Profile Any | Out-Null
} else {
    # Windows 会把 FPGA 直连链路归类为 Public；下面的地址和端口过滤
    # 仍将规则严格限制在 FPGA 数据链路上。
    Set-NetFirewallRule -DisplayName $FirewallRuleName -Enabled True -Direction Inbound -Action Allow -Profile Any | Out-Null
    $rule = Get-NetFirewallRule -DisplayName $FirewallRuleName
    $addressFilter = $rule | Get-NetFirewallAddressFilter
    Set-NetFirewallAddressFilter -InputObject $addressFilter -LocalAddress $Address -RemoteAddress $FpgaAddress | Out-Null
    $portFilter = $rule | Get-NetFirewallPortFilter
    Set-NetFirewallPortFilter -InputObject $portFilter -Protocol UDP -LocalPort $UdpPort -RemotePort Any | Out-Null
}

"SETUP_NETWORK_OK" | Set-Content -Path $ErrorLog -Encoding UTF8
