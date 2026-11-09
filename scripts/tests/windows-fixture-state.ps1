# Read one complete state file while the fixture atomically replaces it. Windows
# readers must allow deletion/rename; default ReadAllText sharing can race Replace.
function Read-WindowsFixtureState([string]$Path) {
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try {
            $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
            try {
                $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
                try { $json = $reader.ReadToEnd() } finally { $reader.Dispose() }
            } finally { $stream.Dispose() }
            return $json | ConvertFrom-Json
        } catch {
            if ($attempt -eq 19) { throw }
            Start-Sleep -Milliseconds 10
        }
    }
}

# Publish a complete command before exposing it to the fixture timer. Directly
# truncating the live file can leave a transient JSON error recorded in its state.
function Write-WindowsFixtureCommand([string]$Path, $Command) {
    $temporary = $Path + '.' + [Guid]::NewGuid() + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($Command | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            try {
                if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, $null) }
                else { [IO.File]::Move($temporary, $Path) }
                return
            } catch [IO.IOException] {
                if ($attempt -eq 19) { throw }
                Start-Sleep -Milliseconds 10
            }
        }
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}
