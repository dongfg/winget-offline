param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$ReadyFile)
$ErrorActionPreference = 'Stop'
# TcpListener avoids HttpListener URL ACL requirements. Only flat, hash-named payloads are served.
$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
try {
    $listener.Start()
    [IO.File]::WriteAllText($ReadyFile, [string]$listener.LocalEndpoint.Port)
    while ($true) {
        # Keep the PowerShell job interruptible while idle (AcceptTcpClient blocks Stop-Job).
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 100; continue }
        $client = $listener.AcceptTcpClient()
        try {
            $client.ReceiveTimeout = 5000
            $client.SendTimeout = 30000
            $stream = $client.GetStream()
            $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
            # Read a bounded request header, without unbounded ReadLine allocations.
            $header = New-Object Text.StringBuilder
            while ($header.Length -lt 16384) {
                $value = $reader.Read()
                if ($value -lt 0) { break }
                [void]$header.Append([char]$value)
                if ($header.ToString().EndsWith("`r`n`r`n")) { break }
            }
            $line = ($header.ToString() -split "`r`n")[0]
            $status = '404 Not Found'
            $file = $null
            $headOnly = $false
            if ($line -match '^(GET|HEAD) /packages/([a-f0-9]{64}\.(?:exe|msi|msix|zip)) HTTP/1\.[01]$') {
                $headOnly = $Matches[1] -eq 'HEAD'
                $candidate = Join-Path $Root $Matches[2]
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $file = Get-Item -LiteralPath $candidate; $status = '200 OK' }
            }
            $length = if ($file) { $file.Length } else { 0 }
            $bytes = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`nContent-Length: $length`r`nContent-Type: application/octet-stream`r`nConnection: close`r`n`r`n")
            $stream.Write($bytes, 0, $bytes.Length)
            if ($file -and -not $headOnly) {
                $inputFile = [IO.File]::OpenRead($file.FullName)
                try { $inputFile.CopyTo($stream) } finally { $inputFile.Dispose() }
            }
        } catch {
            Write-Warning $_
        } finally { $client.Close() }
    }
} finally { $listener.Stop() }
