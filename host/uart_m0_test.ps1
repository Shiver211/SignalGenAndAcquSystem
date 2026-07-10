param(
    [string]$Port = "COM10",
    [int]$BaudRate = 115200,
    [int]$Frames = 500
)

function Get-Crc8Atm {
    param([byte[]]$Data)

    [int]$crc = 0
    foreach ($value in $Data) {
        $crc = $crc -bxor $value
        for ($bit = 0; $bit -lt 8; $bit++) {
            if (($crc -band 0x80) -ne 0) {
                $crc = (($crc -shl 1) -bxor 0x07) -band 0xFF
            } else {
                $crc = ($crc -shl 1) -band 0xFF
            }
        }
    }
    return [byte]$crc
}

function Test-Echo {
    param(
        [System.IO.Ports.SerialPort]$Serial,
        [byte[]]$Data,
        [int]$TimeoutMs = 1000
    )

    $Serial.DiscardInBuffer()
    $Serial.Write($Data, 0, $Data.Length)

    $received = [Collections.Generic.List[byte]]::new()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (($received.Count -lt $Data.Length) -and
           ($watch.ElapsedMilliseconds -lt $TimeoutMs)) {
        $available = $Serial.BytesToRead
        if ($available -gt 0) {
            $chunk = [byte[]]::new([Math]::Min($available, $Data.Length - $received.Count))
            $count = $Serial.Read($chunk, 0, $chunk.Length)
            for ($index = 0; $index -lt $count; $index++) {
                $received.Add($chunk[$index])
            }
        } else {
            Start-Sleep -Milliseconds 1
        }
    }
    $watch.Stop()

    $actual = $received.ToArray()
    $passed = ($actual.Length -eq $Data.Length) -and
              ([BitConverter]::ToString($actual) -ceq [BitConverter]::ToString($Data))

    return [PSCustomObject]@{
        Passed    = $passed
        Sent      = $Data.Length
        Received  = $actual.Length
        LatencyMs = $watch.Elapsed.TotalMilliseconds
    }
}

$serial = [System.IO.Ports.SerialPort]::new(
    $Port,
    $BaudRate,
    [System.IO.Ports.Parity]::None,
    8,
    [System.IO.Ports.StopBits]::One
)
$serial.ReadTimeout = 100
$serial.WriteTimeout = 2000
$serial.DtrEnable = $false
$serial.RtsEnable = $false

$random = [Random]::new(0xC011)
$latencies = [Collections.Generic.List[double]]::new()
$totalBytes = 0

try {
    $serial.Open()
    Start-Sleep -Milliseconds 100
    $serial.DiscardInBuffer()

    # 覆盖全部 8bit 取值；256 字节连续发送是 M0 的基础压力用例。
    $allValues = [byte[]]::new(256)
    for ($index = 0; $index -lt 256; $index++) {
        $allValues[$index] = [byte]$index
    }
    $result = Test-Echo -Serial $serial -Data $allValues -TimeoutMs 3000
    if (-not $result.Passed) {
        throw "All-values test failed: sent=$($result.Sent), received=$($result.Received)"
    }
    $totalBytes += $result.Sent
    $latencies.Add($result.LatencyMs)

    # 模拟控制协议：AA 55 | CMD | LEN | PAYLOAD | CRC8，逐帧等待回显。
    for ($sequence = 0; $sequence -lt $Frames; $sequence++) {
        $payloadLength = $sequence % 32
        $frame = [Collections.Generic.List[byte]]::new()
        $frame.Add(0xAA)
        $frame.Add(0x55)
        $frame.Add([byte]($sequence -band 0xFF))
        $frame.Add([byte]$payloadLength)

        $payload = [byte[]]::new($payloadLength)
        $random.NextBytes($payload)
        foreach ($value in $payload) {
            $frame.Add($value)
        }
        $frame.Add((Get-Crc8Atm -Data $frame.ToArray()))

        $result = Test-Echo -Serial $serial -Data $frame.ToArray()
        if (-not $result.Passed) {
            throw "Control frame $sequence failed: sent=$($result.Sent), received=$($result.Received)"
        }
        $totalBytes += $result.Sent
        $latencies.Add($result.LatencyMs)
        Start-Sleep -Milliseconds 2
    }
} finally {
    if ($serial.IsOpen) {
        $serial.Close()
    }
    $serial.Dispose()
}

$averageLatency = ($latencies | Measure-Object -Average).Average
$maximumLatency = ($latencies | Measure-Object -Maximum).Maximum

[PSCustomObject]@{
    Port             = $Port
    BaudRate         = $BaudRate
    ControlFrames    = $Frames
    TotalBytes       = $totalBytes
    AverageLatencyMs = [Math]::Round($averageLatency, 3)
    MaximumLatencyMs = [Math]::Round($maximumLatency, 3)
    Result           = "UART_M0_HW_PASS"
}
