[CmdletBinding()]
param(
    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
    [string]$At = '06:00'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $PSScriptRoot 'refresh-kyc-sanctions-local.cjs'
$node = (Get-Command node.exe -CommandType Application | Select-Object -First 1).Source
$pythonCommand = (Get-Command python.exe -CommandType Application | Select-Object -First 1).Source
$python = & $pythonCommand -c 'import sys; print(sys.executable)'
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $python -PathType Leaf)) {
    throw 'A working Python executable is required.'
}

# Validate and install once before registering the recurring data-only job.
& $node $runner $python --install
if ($LASTEXITCODE -ne 0) { throw 'Initial sanctions refresh failed. Task registration stopped.' }

$taskName = 'CoreAML Local Sanctions Watchlist Refresh'
$start = [DateTime]::ParseExact($At, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
$action = New-ScheduledTaskAction -Execute $node -Argument ('"{0}" "{1}"' -f $runner, $python) -WorkingDirectory $root
$trigger = New-ScheduledTaskTrigger -Daily -At $start
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Get-ScheduledTaskInfo -TaskName $taskName | Select-Object TaskName, NextRunTime
