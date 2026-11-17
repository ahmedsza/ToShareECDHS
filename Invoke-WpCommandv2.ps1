<#
.SYNOPSIS
    Runs commands over an Azure Linux App Service SSH tunnel with live output.

.DESCRIPTION
    Opens or reuses the same verified tunnels as Invoke-WpCommand.ps1.
    Streams stdout and stderr to the host while each command runs, including
    output without a newline. Stderr is displayed in red, even on exit code 0.
    Returns the same Command, ExitCode, Output, Error, and Success properties.
    Output and Error retain the complete captured text, including line endings.
    Display remains live when the returned results are assigned to a variable.
    Remote programs may still buffer their own output.

.NOTES
    Requires: PowerShell 7+, Azure CLI (logged in), Posh-SSH module.
    Install-Module Posh-SSH -Scope CurrentUser
    -ReuseTunnel and -CloseTunnel require Windows and track tunnels per target.
    -CommandTimeoutSeconds includes execution and output collection; a timeout
    cancels the SSH command and raises an error instead of returning success.
    SensitiveValue redacts command display, not remote stdout or stderr.

.EXAMPLE
    .\Invoke-WpCommandv2.ps1 -ResourceGroup rg-wp -AppName my-wp-site -Command 'wp plugin list'

.EXAMPLE
    $result = .\Invoke-WpCommandv2.ps1 -ResourceGroup rg-wp -AppName my-wp-site -ReuseTunnel -Command $BashCommand

.EXAMPLE
    .\Invoke-WpCommandv2.ps1 -ResourceGroup rg-wp -AppName my-wp-site -Interactive

.EXAMPLE
    .\Invoke-WpCommandv2.ps1 -ResourceGroup rg-wp -AppName my-wp-site -CloseTunnel
#>

[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $AppName,
    [string] $Slot,
    [string] $SubscriptionId,

    [Parameter(ParameterSetName = 'Run')]
    [string[]] $Command,

    [Parameter(ParameterSetName = 'Shell')]
    [switch] $Interactive,

    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Shell')]
    [switch] $ReuseTunnel,

    [Parameter(Mandatory, ParameterSetName = 'Close')]
    [switch] $CloseTunnel,

    [ValidateRange(1, 65535)] [int] $Port = 2222,
    [string] $WorkingDirectory = '/home/site/wwwroot',
    [ValidateRange(1, 86400)] [int] $TunnelTimeoutSeconds = 60,
    [ValidateRange(1, 86400)] [int] $CommandTimeoutSeconds = 3600,
    [string[]] $SensitiveValue
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# These fixed base-image credentials are only reachable through the authenticated tunnel.
$ContainerUser = 'root'
$ContainerPass = 'Docker!'

function Write-Step { param($m) Write-Host "`n> $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "  OK $m" -ForegroundColor Green }

function ConvertTo-BashLiteral {
    param([AllowEmptyString()][string] $Value)

    return "'" + $Value.Replace("'", "'`"'`"'") + "'"
}

function New-LoginShellCommand {
    param([string] $Command)

    $directory = ConvertTo-BashLiteral $WorkingDirectory
    $loginCommand = ConvertTo-BashLiteral $Command
    return "cd -- $directory && bash -lc $loginCommand"
}

function Protect-CommandDisplay {
    param([string] $Value)

    foreach ($secret in $SensitiveValue) {
        if ($secret) { $Value = $Value.Replace($secret, '[REDACTED]') }
    }
    return $Value
}

function Invoke-StreamingCommand {
    param(
        [Parameter(Mandatory)] $Client,
        [Parameter(Mandatory)] [string] $Command,
        [ValidateRange(1, 86400)] [int] $TimeoutSeconds = 3600
    )

    $sshCommand = $Client.CreateCommand($Command)
    $async = $null
    $streams = @()
    try {
        $sshCommand.CommandTimeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $async = $sshCommand.BeginExecute()
        foreach ($isError in @($false, $true)) {
            $stream = if ($isError) { $sshCommand.ExtendedOutputStream } else { $sshCommand.OutputStream }
            $stream.BlockLastReadBuffer = $false
            $streams += [pscustomobject]@{
                Stream = $stream
                Decoder = [Text.Encoding]::UTF8.GetDecoder()
                Text = [Text.StringBuilder]::new()
                IsError = $isError
            }
        }
        $buffer = [byte[]]::new(4096)
        $characters = [char[]]::new([Text.Encoding]::UTF8.GetMaxCharCount($buffer.Length))

        # Read only available bytes: PipeStream otherwise waits for a full buffer.
        while ($true) {
            if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                throw [TimeoutException]::new("SSH command exceeded $TimeoutSeconds seconds.")
            }
            $madeProgress = $false
            foreach ($state in $streams) {
                $available = [int][Math]::Min($state.Stream.Length, $buffer.Length)
                if ($available -eq 0) { continue }
                $count = $state.Stream.Read($buffer, 0, $available)
                if ($count -eq 0) { throw 'SSH output stream closed before buffered output could be read.' }
                $madeProgress = $true
                $characterCount = $state.Decoder.GetChars($buffer, 0, $count, $characters, 0, $false)
                $text = [string]::new($characters, 0, $characterCount)
                $null = $state.Text.Append($text)
                if ($state.IsError) { Write-Host -NoNewline $text -ForegroundColor Red }
                else { Write-Host -NoNewline $text }
            }
            if ($async.IsCompleted -and $streams[0].Stream.Length -eq 0 -and $streams[1].Stream.Length -eq 0) {
                break
            }
            if (-not $madeProgress) { Start-Sleep -Milliseconds 20 }
        }

        $null = $sshCommand.EndExecute($async)
        foreach ($state in $streams) {
            $characterCount = $state.Decoder.GetChars($buffer, 0, 0, $characters, 0, $true)
            if ($characterCount -gt 0) {
                $text = [string]::new($characters, 0, $characterCount)
                $null = $state.Text.Append($text)
                if ($state.IsError) { Write-Host -NoNewline $text -ForegroundColor Red }
                else { Write-Host -NoNewline $text }
            }
        }
        if ($null -eq $sshCommand.ExitStatus -or $sshCommand.ExitStatus -lt 0) {
            throw 'SSH command completed without an exit status.'
        }
        Write-Host ''
        [pscustomobject]@{
            ExitStatus = $sshCommand.ExitStatus
            Output = $streams[0].Text.ToString()
            Error = $streams[1].Text.ToString()
        }
    }
    finally {
        try {
            if ($null -ne $async -and -not $async.IsCompleted) { $sshCommand.CancelAsync() }
        }
        finally {
            $sshCommand.Dispose()
        }
    }
}

function Test-PortFree {
    param([int]$P)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $P)
    try {
        $listener.Start()
        return $true
    }
    catch [System.Net.Sockets.SocketException] {
        if ($_.Exception.SocketErrorCode -notin @('AddressAlreadyInUse', 'AccessDenied')) { throw }
        Write-Host "  Port $P unavailable ($($_.Exception.SocketErrorCode))" -ForegroundColor Yellow
        return $false
    }
    finally { $listener.Stop() }
}

function Get-TunnelTargetKey {
    param([string] $Subscription, [string] $Group, [string] $App, [string] $DeploymentSlot)

    $target = (@($Subscription, $Group, $App, $DeploymentSlot) | ForEach-Object { $_.ToLowerInvariant() }) | ConvertTo-Json -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($target))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Enter-TunnelLock {
    param([string] $StatePath)

    try { return [IO.File]::Open("$StatePath.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch [IO.IOException] { throw 'This target tunnel is busy in another invocation. Retry after it finishes.' }
}

function Read-TunnelState {
    param([string] $StatePath, [string] $TargetKey)

    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    try {
        $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -AsHashtable
        if ($state.Version -ne 1 -or $state.TargetKey -cne $TargetKey -or
            [int] $state.ProcessId -le 0 -or [int] $state.Port -lt 1 -or [int] $state.Port -gt 65535 -or
            -not $state.StartTicks -or -not $state.EncodedCommand) { throw 'Invalid tunnel metadata.' }
        return $state
    }
    catch { throw "Cannot verify tunnel state at '$StatePath'. No process was reused or stopped. $($_.Exception.Message)" }
}

function Save-TunnelState {
    param([string] $StatePath, [hashtable] $State)

    $temporary = "$StatePath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $State | ConvertTo-Json -Compress | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
        [IO.File]::Move($temporary, $StatePath, $true)
    }
    finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

function Get-VerifiedTunnelProcess {
    param([hashtable] $State)

    $process = Get-Process -Id $State.ProcessId -ErrorAction SilentlyContinue
    if (-not $process -or $process.HasExited -or
        "$($process.StartTime.ToUniversalTime().Ticks)" -cne [string] $State.StartTicks) { return $null }
    $details = Get-CimInstance Win32_Process -Filter "ProcessId = $($process.Id)" -ErrorAction Stop
    if (-not $details -or -not $details.CommandLine -or
        $details.CommandLine -notmatch ('-EncodedCommand\s+"?' + [regex]::Escape($State.EncodedCommand) + '"?(?:\s|$)')) {
        throw 'Tracked process identity could not be verified. No process was reused or stopped.'
    }
    return $process
}

function Test-OwnedTunnelListener {
    param([System.Diagnostics.Process] $Process, [int] $LocalPort)

    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop |
        Where-Object { $_.LocalPort -eq $LocalPort })
    if (-not $listeners.Count) { return $false }
    $processes = @{}
    foreach ($entry in Get-CimInstance Win32_Process -ErrorAction Stop) { $processes[[int] $entry.ProcessId] = $entry }
    foreach ($connection in $listeners) {
        if ($connection.LocalAddress -notin @('127.0.0.1', '::1')) { return $false }
        $ownerId = [int] $connection.OwningProcess
        $seen = @{}
        while ($ownerId -ne $Process.Id) {
            if ($seen.ContainsKey($ownerId) -or -not $processes.ContainsKey($ownerId)) { return $false }
            $seen[$ownerId] = $true
            $entry = $processes[$ownerId]
            if ($entry.CreationDate.ToUniversalTime() -lt $Process.StartTime.ToUniversalTime()) { return $false }
            $ownerId = [int] $entry.ParentProcessId
        }
    }
    return $true
}

function Stop-OwnedTunnelProcess {
    param([Parameter(Mandatory)] [System.Diagnostics.Process] $Process)

    if (-not $Process.HasExited) {
        $Process.Kill($true)
        if (-not $Process.WaitForExit(10000)) {
            throw "Tunnel process $($Process.Id) did not exit."
        }
    }
}

function Stop-Tunnel {
    if ($tunnel) {
        Write-Step 'Closing tunnel'
        Stop-OwnedTunnelProcess -Process $tunnel
        if ($IsWindows) {
            $releaseDeadline = [DateTime]::UtcNow.AddSeconds(10)
            do {
                $listening = @(Get-NetTCPConnection -State Listen -ErrorAction Stop |
                    Where-Object { $_.LocalPort -eq $Port }).Count -gt 0
            } while ($listening -and [DateTime]::UtcNow -lt $releaseDeadline)
            if ($listening) {
                throw "Tunnel process stopped, but port $Port still has a listener. State and logs were retained for inspection."
            }
        }
        Write-Ok 'Tunnel closed'
    }
    if ($statePath) { Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $outLog, $errLog -Force -ErrorAction SilentlyContinue
}

Write-Step 'Checking prerequisites'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7+ required (found $($PSVersionTable.PSVersion))."
}
if (($ReuseTunnel -or $CloseTunnel) -and -not $IsWindows) {
    throw 'Verified tunnel reuse and close currently require Windows. Temporary tunnels remain supported on other platforms.'
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI not found. Install: https://aka.ms/installazurecli'
}
$accountArgs = @('account', 'show', '--output', 'json')
if ($SubscriptionId) { $accountArgs += @('--subscription', $SubscriptionId) }
$accountJson = & az @accountArgs
if ($LASTEXITCODE -ne 0 -or -not $accountJson) { throw 'Cannot resolve subscription. Check az login and -SubscriptionId.' }
$account = ($accountJson -join "`n") | ConvertFrom-Json
$SubscriptionId = $account.id
if (-not $SubscriptionId) { throw 'Azure CLI did not return a subscription ID.' }
if ($Slot -eq 'production') { $Slot = '' }

if (-not $Interactive -and -not $CloseTunnel) {
    if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
        Write-Host '  Installing Posh-SSH...' -ForegroundColor Yellow
        Install-Module Posh-SSH -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module Posh-SSH -ErrorAction Stop
}
Write-Ok "Prerequisites OK (subscription $SubscriptionId)"

$statePath = $null
$targetKey = $null
$lock = $null
$tunnel = $null
$retainTunnel = $false
$launchAttempted = $false
$outLog = $null
$errLog = $null

try {
    if ($ReuseTunnel -or $CloseTunnel) {
        $targetKey = Get-TunnelTargetKey -Subscription $SubscriptionId -Group $ResourceGroup -App $AppName -DeploymentSlot $Slot
        $stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WordPressOnAzureToolkit/tunnels'
        $null = New-Item -ItemType Directory -Path $stateRoot -Force
        $statePath = Join-Path $stateRoot "$targetKey.json"
        $lock = Enter-TunnelLock -StatePath $statePath
        $outLog = "$statePath.out"
        $errLog = "$statePath.err"
        $state = Read-TunnelState -StatePath $statePath -TargetKey $targetKey
        if ($state) {
            $verified = Get-VerifiedTunnelProcess -State $state
            if ($verified) {
                $tunnel = $verified
                $Port = [int] $state.Port
                $retainTunnel = $true
                if (-not $CloseTunnel -and -not (Test-OwnedTunnelListener -Process $tunnel -LocalPort $Port)) {
                    throw 'Tracked tunnel has no verified loopback listener. Use -CloseTunnel, then retry -ReuseTunnel.'
                }
                Write-Ok "Verified existing tunnel on 127.0.0.1:$Port (PID $($tunnel.Id))"
            }
            else {
                Write-Warning 'Discarding stale tunnel metadata; no matching process was stopped.'
                Remove-Item -LiteralPath $statePath -Force
            }
        }
        if ($CloseTunnel) {
            if ($tunnel) { Stop-Tunnel; $tunnel = $null }
            else {
                Remove-Item -LiteralPath $outLog, $errLog -Force -ErrorAction SilentlyContinue
                Write-Ok 'No matching retained tunnel is running'
            }
            return
        }
    }

    if (-not $tunnel) {
        while (-not (Test-PortFree $Port)) {
            if ($Port -eq 65535) { throw 'No available local port in the requested range.' }
            $Port++
        }
        Write-Step "Opening remote connection tunnel on localhost:$Port"
        $azArgs = @('webapp', 'create-remote-connection', '--resource-group', $ResourceGroup,
            '--name', $AppName, '--port', "$Port", '--subscription', $SubscriptionId)
        if ($Slot) { $azArgs += @('--slot', $Slot) }
        $argumentLiteral = ($azArgs | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ', '
        $azPath = (Get-Command az).Source.Replace("'", "''")
        $launch = "& '$azPath' @($argumentLiteral); exit `$LASTEXITCODE"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launch))
        if (-not $outLog) { $outLog = [IO.Path]::GetTempFileName(); $errLog = [IO.Path]::GetTempFileName() }
        $startArgs = @{
            FilePath = (Get-Command pwsh -ErrorAction Stop).Source
            ArgumentList = @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded)
            RedirectStandardOutput = $outLog
            RedirectStandardError = $errLog
            PassThru = $true
        }
        if ($IsWindows) { $startArgs.WindowStyle = 'Hidden' }
        $launchAttempted = $true
        $tunnel = Start-Process @startArgs
        $state = @{
            Version = 1; TargetKey = $targetKey; Port = $Port; ProcessId = $tunnel.Id
            StartTicks = "$($tunnel.StartTime.ToUniversalTime().Ticks)"; EncodedCommand = $encoded
        }
        $deadline = [DateTime]::UtcNow.AddSeconds($TunnelTimeoutSeconds)
        $ready = $false
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($tunnel.HasExited) {
                $err = (Get-Content -LiteralPath $errLog -Raw), (Get-Content -LiteralPath $outLog -Raw) -join "`n"
                throw "Tunnel process exited early:`n$err"
            }
            if ($IsWindows) {
                $ready = Test-OwnedTunnelListener -Process $tunnel -LocalPort $Port
            }
            else {
                $client = [Net.Sockets.TcpClient]::new()
                try { $ready = $client.ConnectAsync('127.0.0.1', $Port).Wait(500) -and $client.Connected }
                catch { $ready = $false }
                finally { $client.Dispose() }
            }
            if ($ready) { break }
            $null = $tunnel.WaitForExit(250)
        }
        if (-not $ready) { throw "Tunnel did not become ready within $TunnelTimeoutSeconds seconds." }
        Write-Ok "Tunnel listener ready on 127.0.0.1:$Port (PID $($tunnel.Id))"
    }

    if ($Interactive) {
        Write-Host ''
        Write-Host '  Connecting with your system ssh client.' -ForegroundColor Cyan
        Write-Host "  Password when prompted: $ContainerPass" -ForegroundColor Yellow
        Write-Host ''
        ssh "$ContainerUser@127.0.0.1" -p $Port `
            -o StrictHostKeyChecking=no `
            -o UserKnownHostsFile=/dev/null `
            -o LogLevel=ERROR
        if ($LASTEXITCODE -ne 0) { throw "SSH exited with code $LASTEXITCODE." }
        if ($ReuseTunnel -and -not $retainTunnel) {
            Save-TunnelState -StatePath $statePath -State $state
            $retainTunnel = $true
        }
        return
    }

    Write-Step 'Authenticating to the container'

    $secure = ConvertTo-SecureString $ContainerPass -AsPlainText -Force
    $cred   = [pscredential]::new($ContainerUser, $secure)

    $session = New-SSHSession -ComputerName '127.0.0.1' -Port $Port `
                              -Credential $cred -AcceptKey -Force `
                              -ConnectionTimeout 30
    Write-Ok "SSH session $($session.SessionId) established"

    try {
        if ($ReuseTunnel -and -not $retainTunnel) {
            Save-TunnelState -StatePath $statePath -State $state
            $retainTunnel = $true
        }
        $probe = Invoke-SSHCommand -SessionId $session.SessionId `
                    -Command (New-LoginShellCommand 'wp core version --allow-root') `
                    -TimeOut 60
        if ($probe.ExitStatus -ne 0) {
            throw "WP-CLI unavailable in $WorkingDirectory`n$($probe.Error -join "`n")"
        }
        Write-Ok "WordPress $($probe.Output -join '')"

        if (-not $Command) {
            Write-Host "`n  No -Command supplied. Use -Interactive for a shell." -ForegroundColor Yellow
            return
        }

        $results = foreach ($c in $Command) {
            $full = if ($c -match '^\s*wp\b' -and $c -notmatch '--allow-root') {
                "$c --allow-root"
            } else { $c }

            $displayCommand = Protect-CommandDisplay $full
            Write-Step $displayCommand

            $r = Invoke-StreamingCommand -Client $session.Session `
                    -Command (New-LoginShellCommand $full) `
                    -TimeoutSeconds $CommandTimeoutSeconds

            if ($r.ExitStatus -ne 0) {
                Write-Host "    exit $($r.ExitStatus)" -ForegroundColor Red
            }

            [pscustomobject]@{
                Command  = $displayCommand
                ExitCode = $r.ExitStatus
                Output   = $r.Output
                Error    = $r.Error
                Success  = ($r.ExitStatus -eq 0)
            }
        }

        Write-Host ''
        $results | Format-Table Command, ExitCode, Success -AutoSize | Out-Host
        return $results
    }
    finally {
        Remove-SSHSession -SessionId $session.SessionId -ErrorAction SilentlyContinue | Out-Null
    }
}
finally {
    try {
        if (-not $retainTunnel -and ($tunnel -or $launchAttempted)) { Stop-Tunnel }
        elseif ($tunnel -and -not $CloseTunnel) { Write-Ok "Tunnel retained on port $Port; use -CloseTunnel for this target when finished" }
    }
    finally { if ($lock) { $lock.Dispose() } }
}
