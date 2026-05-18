[CmdletBinding()]
param(
    [string]$Repo = ".",
    [string]$Workspace,
    [string]$List,
    [Alias("m")]
    [string[]]$Message,
    [switch]$DryRun,
    [switch]$NoVerify
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pythonScript = Join-Path $scriptDir "commit_changelist.py"

$pythonArgs = @($pythonScript, "--repo", $Repo)
if ($Workspace) {
    $pythonArgs += @("--workspace", $Workspace)
}
if ($List) {
    $pythonArgs += @("--list", $List)
}
if ($Message) {
    foreach ($item in $Message) {
        $pythonArgs += @("-m", $item)
    }
}
if ($DryRun) {
    $pythonArgs += "--dry-run"
}
if ($NoVerify) {
    $pythonArgs += "--no-verify"
}

$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) {
    & $python.Source @pythonArgs
    exit $LASTEXITCODE
}

$py = Get-Command py -ErrorAction SilentlyContinue
if ($py) {
    & $py.Source -3 @pythonArgs
    exit $LASTEXITCODE
}

Write-Error "Python 3 is required to run commit_changelist.ps1"
exit 1
