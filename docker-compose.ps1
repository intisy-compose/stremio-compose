#Requires -Version 5.1
param([string]$Command = "up")

$forwarded = $args

Set-StrictMode -Version Latest

function Write-Step([string]$msg) { Write-Host $msg -ForegroundColor Cyan }
function Write-OK([string]$msg)   { Write-Host "  $msg" -ForegroundColor Green }
function Write-Err([string]$msg)  { Write-Host $msg -ForegroundColor Red }

function Import-Config([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    Get-Content $Path |
        Where-Object { $_ -notmatch '^\s*#' -and $_ -match '=' } |
        ForEach-Object {
            $k, $v = $_ -split '=', 2
            Set-Item "env:$($k.Trim())" $v.Trim()
        }
}

function Show-Usage([hashtable]$Commands) {
    $width = ($Commands.Keys | Measure-Object -Property Length -Maximum).Maximum
    Write-Host "Usage: .\docker-compose.ps1 [$(($Commands.Keys | Sort-Object) -join '|')]"
    foreach ($cmd in $Commands.Keys | Sort-Object) {
        Write-Host ("  {0}  {1}" -f $cmd.PadRight($width), $Commands[$cmd])
    }
}

# Selects the tailscale serve config that docker-compose.yml mounts. Anything
# other than an explicit truthy PUBLIC_ACCESS stays tailnet-only, so a typo can
# only ever fail closed.
function Resolve-ServeFile {
    $public = "$env:PUBLIC_ACCESS".Trim().ToLower() -in @("1", "true", "yes", "on")
    $env:TS_SERVE_FILE = if ($public) { "funnel.json" } else { "serve.json" }
    return $public
}

function Get-TailnetName {
    $raw = docker compose exec -T tailscale tailscale status --json 2>$null
    if (-not $raw) { return $null }
    try {
        $status = $raw | Out-String | ConvertFrom-Json
        if ($status.BackendState -ne "Running" -or -not $status.Self.DNSName) { return $null }
        return $status.Self.DNSName.TrimEnd('.')
    } catch { return $null }
}

function Set-ConfigValue([string]$Name, [string]$Value) {
    $path = "$PSScriptRoot\config.env"
    $lines = @(if (Test-Path $path) { Get-Content $path })
    if ($lines -match "^\s*$Name\s*=") { $lines = $lines -replace "^\s*$Name\s*=.*$", "$Name=$Value" }
    else { $lines += "$Name=$Value" }
    [System.IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"))
    Set-Item "env:$Name" $Value
}

# The gateway's certificate is for the ts.net name, so the node joins first and its name is
# written to STREMIO_HOST before the gateway starts with it.
function Connect-Tailnet {
    Write-Step "Joining the tailnet..."
    docker compose up -d tailscale
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        $dns = Get-TailnetName
        if ($dns) {
            Write-OK "Joined as $dns"
            if ($env:STREMIO_HOST -ne $dns) { Set-ConfigValue "STREMIO_HOST" $dns; Write-OK "Wrote STREMIO_HOST to config.env." }
            return
        }
        Start-Sleep -Seconds 2
    }
    Write-Err "The node did not join within 90s (an expired or used-up TS_AUTHKEY is the usual cause);"
    Write-Err "the server is on http://localhost:11470 only. Check '.\docker-compose.ps1 logs'."
}

# Prints the tailnet HTTPS URL clients should point Stremio at. Reads the live
# node identity from the running tailscale container so the tailnet name is real,
# not guessed.
function Show-Url {
    $deadline = (Get-Date).AddSeconds(30)
    $dns = Get-TailnetName
    while (-not $dns -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $dns = Get-TailnetName
    }
    if (-not $dns) { Write-Err "Node not on the tailnet yet - run 'up' first, or check 'logs'."; return }
    Write-Host ""
    if ($script:IsPublic) {
        Write-OK "Public streaming server URL - share this with friends:"
        Write-Host "    https://$dns/" -ForegroundColor Yellow
        Write-Host "    Reachable from the open internet, with no login. Anyone who" -ForegroundColor DarkYellow
        Write-Host "    has the URL can stream and download through your connection." -ForegroundColor DarkYellow
    } else {
        Write-OK "Streaming server URL (set this in web.stremio.com -> Settings):"
        Write-Host "    https://$dns/" -ForegroundColor Yellow
    }
    Write-Host "  On this PC: http://localhost:11470/"
}

function Invoke-Data([object[]]$DataArguments) {
    $subcommand = if ($DataArguments) { "$($DataArguments[0])".ToLower() } else { "status" }
    switch ($subcommand) {
        "status" { git -C $PSScriptRoot submodule status -- data; break }
        "use" {
            $source = if ($DataArguments.Count -ge 2) { "$($DataArguments[1])" } else { "" }
            if ($source) {
                $parts = $source.Split("@", 2)
                $url = if ($parts[0] -match "://|^git@") { $parts[0] } else { "https://github.com/$($parts[0]).git" }
                $ref = if ($parts.Count -eq 2) { $parts[1] } else { "main" }
            } else {
                $url = git -C $PSScriptRoot config -f .gitmodules submodule.data.url
                $ref = "main"
            }
            Write-Step "Pointing data at $url @ $ref"
            if (-not (Test-Path "$PSScriptRoot\data\.git")) { git -C $PSScriptRoot submodule update --init -- data 2>$null | Out-Null }
            git -C $PSScriptRoot config submodule.data.url $url
            git -C "$PSScriptRoot\data" remote set-url origin $url
            git -C "$PSScriptRoot\data" fetch -q origin $ref
            git -C "$PSScriptRoot\data" checkout -q FETCH_HEAD
            Write-OK "data now at $(git -C "$PSScriptRoot\data" rev-parse --short HEAD)"
            break
        }
        default { Show-Usage -Commands $usage; exit 1 }
    }
}

Set-Location $PSScriptRoot
Import-Config "$PSScriptRoot\config.env"
$script:IsPublic = Resolve-ServeFile

$usage = @{
    "up"      = "Start the stack (default)"
    "down"    = "Stop and remove everything"
    "restart" = "Recreate the stack"
    "logs"    = "Follow logs"
    "url"     = "Print the HTTPS URL to use in web.stremio.com"
    "data"    = "status | use [owner/repo[@ref]]  point data/ at a data repo (none = template)"
}

switch ($Command.ToLower()) {
    "up" {
        # The auth key is only needed for the FIRST join; after that the node
        # identity lives in data/tailscale and the key can be blanked out.
        $joined = Test-Path "$PSScriptRoot\data\tailscale\tailscaled.state" -PathType Leaf
        if (-not $joined) { $joined = Test-Path "$PSScriptRoot\data\tailscale\profile-data" }
        if (-not $env:TS_AUTHKEY -and -not $joined) {
            Write-Err "TS_AUTHKEY is empty in config.env and this node hasn't joined yet."
            Write-Err "Create a key at https://login.tailscale.com/admin/settings/keys"
            exit 1
        }
        if ($script:IsPublic) { Write-Step "PUBLIC_ACCESS is on - serving over Tailscale Funnel." }
        Connect-Tailnet
        Write-Step "Starting stremio..."
        docker compose up -d
        Show-Url
        Write-Host "`nPress Enter to exit..."; $null = Read-Host
        break
    }
    "down"    { Write-Step "Stopping everything..."; docker compose down; break }
    "restart" { Write-Step "Recreating..."; Connect-Tailnet; docker compose up -d --force-recreate; Show-Url; break }
    "logs"    { docker compose logs -f; break }
    "url"     { Show-Url; break }
    "data"    { Invoke-Data $forwarded; break }
    default   { Show-Usage -Commands $usage; exit 1 }
}
