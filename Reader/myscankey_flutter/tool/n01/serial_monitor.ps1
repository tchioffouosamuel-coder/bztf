param(
    [string]$Port = 'COM18',
    [int]$BaudRate = 115200
)

$ErrorActionPreference = 'Stop'
$serial = [System.IO.Ports.SerialPort]::new(
    $Port, $BaudRate, [System.IO.Ports.Parity]::None,
    8, [System.IO.Ports.StopBits]::One
)
$serial.Handshake = [System.IO.Ports.Handshake]::None
$serial.DtrEnable = $false
$serial.RtsEnable = $false
$serial.Encoding = [System.Text.UTF8Encoding]::new($false)
$serial.WriteTimeout = 1000
$pending = [System.Text.StringBuilder]::new()
$previousControlC = [Console]::TreatControlCAsInput

try {
    $serial.Open()
    $Host.UI.RawUI.WindowTitle = "Moniteur serie N01 - $Port"
    [Console]::TreatControlCAsInput = $true
    Write-Host "$Port ouvert : $BaudRate bauds, 8N1, sans controle de flux." -ForegroundColor Green
    Write-Host 'Entree : envoyer la commande. Ctrl+C : fermer le port.'
    Write-Host 'Identifiant : {"OP":"ReaderIdGet"}'
    Write-Host 'Version     : {"OP":"VersionGet"}'
    Write-Host ''

    while ($true) {
        $received = $serial.ReadExisting()
        if ($received.Length -gt 0) {
            [Console]::Write($received)
        }

        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::C -and
                ($key.Modifiers -band [ConsoleModifiers]::Control)) {
                break
            }
            switch ($key.Key) {
                Enter {
                    if ($pending.Length -gt 0) {
                        # The N01 SDK sends JSON without a line terminator.
                        $serial.Write($pending.ToString())
                        [void]$pending.Clear()
                    }
                    [Console]::WriteLine()
                }
                Backspace {
                    if ($pending.Length -gt 0) {
                        $pending.Length--
                        [Console]::Write("`b `b")
                    }
                }
                default {
                    if (-not [char]::IsControl($key.KeyChar)) {
                        [void]$pending.Append($key.KeyChar)
                        [Console]::Write($key.KeyChar)
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 20
    }
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
} finally {
    [Console]::TreatControlCAsInput = $previousControlC
    $serial.Dispose()
    Write-Host "`n$Port ferme."
}
