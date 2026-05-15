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

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string[]]$Args,
        [string]$IndexFile,
        [switch]$AllowFailure
    )

    $previousIndex = $env:GIT_INDEX_FILE
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        if ($IndexFile) {
            $env:GIT_INDEX_FILE = $IndexFile
        }
        $ErrorActionPreference = "Continue"
        $output = & git -C $RepoRoot @Args 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($null -eq $previousIndex) {
            Remove-Item Env:\GIT_INDEX_FILE -ErrorAction SilentlyContinue
        }
        else {
            $env:GIT_INDEX_FILE = $previousIndex
        }
    }

    if ($code -ne 0 -and -not $AllowFailure) {
        if ($output) { $output | ForEach-Object { Write-Error $_ } }
        exit $code
    }

    [pscustomobject]@{
        Code = $code
        Output = $output
    }
}

function Test-HasHead {
    param([string]$RepoRoot)

    $result = Invoke-Git -RepoRoot $RepoRoot -Args @("rev-parse", "--verify", "--quiet", "HEAD") -AllowFailure
    return $result.Code -eq 0
}

function Test-RealIndexMatchesWorktree {
    param(
        [string]$RepoRoot,
        [string[]]$Paths
    )

    $diffArgs = @("diff", "--quiet", "--") + $Paths
    $diff = Invoke-Git -RepoRoot $RepoRoot -Args $diffArgs -AllowFailure
    if ($diff.Code -ne 0 -and $diff.Code -ne 1) {
        exit $diff.Code
    }

    $othersArgs = @("ls-files", "--others", "--exclude-standard", "--") + $Paths
    $others = Invoke-Git -RepoRoot $RepoRoot -Args $othersArgs -AllowFailure
    if ($others.Code -ne 0) {
        exit $others.Code
    }

    return $diff.Code -eq 0 -and -not $others.Output
}

function Resolve-RepoRoot {
    param([string]$Start)

    $resolvedStart = (Resolve-Path -LiteralPath $Start).Path
    $result = & git -C $resolvedStart rev-parse --show-toplevel 2>&1
    if ($LASTEXITCODE -ne 0) {
        $result | ForEach-Object { Write-Error $_ }
        exit $LASTEXITCODE
    }
    return (Resolve-Path -LiteralPath $result.Trim()).Path
}

function ConvertTo-RepoRelativePath {
    param(
        [string]$RawPath,
        [string]$RepoRoot
    )

    $marker = '$PROJECT_DIR$'
    if ($RawPath.StartsWith($marker)) {
        $suffix = $RawPath.Substring($marker.Length).TrimStart("/", "\")
        $absolute = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $suffix))
    }
    elseif ([System.IO.Path]::IsPathRooted($RawPath)) {
        $absolute = [System.IO.Path]::GetFullPath($RawPath)
    }
    else {
        $absolute = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $RawPath))
    }

    $repoFull = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $absoluteFull = [System.IO.Path]::GetFullPath($absolute)
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    if (-not $absoluteFull.StartsWith($repoFull + [System.IO.Path]::DirectorySeparatorChar, $comparison) -and
        -not $absoluteFull.Equals($repoFull, $comparison)) {
        throw "Changelist path is outside the repository: $absoluteFull"
    }

    $repoUriPath = $repoFull.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
    $repoUri = New-Object System.Uri($repoUriPath)
    $absoluteUri = New-Object System.Uri($absoluteFull)
    $relative = $repoUri.MakeRelativeUri($absoluteUri).ToString()
    return [System.Uri]::UnescapeDataString($relative).Replace("\", "/")
}

function Get-XmlAttribute {
    param(
        [System.Xml.XmlNode]$Node,
        [string]$Name
    )

    $attribute = $Node.Attributes[$Name]
    if ($null -eq $attribute) {
        return $null
    }
    return $attribute.Value
}

$repoRoot = Resolve-RepoRoot -Start $Repo
$workspacePath = if ($Workspace) {
    (Resolve-Path -LiteralPath $Workspace).Path
} else {
    Join-Path $repoRoot ".idea\workspace.xml"
}

if (-not (Test-Path -LiteralPath $workspacePath)) {
    Write-Error "Missing JetBrains workspace file: $workspacePath"
    exit 1
}

$xml = New-Object System.Xml.XmlDocument
$xml.PreserveWhitespace = $true
$xml.Load($workspacePath)
$component = $xml.SelectSingleNode("//component[@name='ChangeListManager']")
if ($null -eq $component) {
    Write-Error "Missing ChangeListManager component in workspace.xml"
    exit 1
}

$lists = @($component.SelectNodes("list"))
if ($List) {
    $selectedList = $lists | Where-Object {
        (Get-XmlAttribute -Node $_ -Name "name") -eq $List -or
        (Get-XmlAttribute -Node $_ -Name "id") -eq $List
    } | Select-Object -First 1
    if ($null -eq $selectedList) {
        $available = ($lists | ForEach-Object { Get-XmlAttribute -Node $_ -Name "name" }) -join ", "
        Write-Error "Changelist not found: $List. Available: $available"
        exit 1
    }
} else {
    $selectedList = $lists | Where-Object { (Get-XmlAttribute -Node $_ -Name "default") -eq "true" } | Select-Object -First 1
    if ($null -eq $selectedList) {
        Write-Error "No default JetBrains changelist found"
        exit 1
    }
}

$paths = New-Object System.Collections.Generic.List[string]
$seen = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

foreach ($change in @($selectedList.SelectNodes("change"))) {
    foreach ($attribute in @("afterPath", "beforePath")) {
        $raw = Get-XmlAttribute -Node $change -Name $attribute
        if ([string]::IsNullOrWhiteSpace($raw)) {
            continue
        }
        $relative = ConvertTo-RepoRelativePath -RawPath $raw -RepoRoot $repoRoot
        if ($seen.Add($relative)) {
            $paths.Add($relative)
        }
    }
}

$name = Get-XmlAttribute -Node $selectedList -Name "name"
$id = Get-XmlAttribute -Node $selectedList -Name "id"
$comment = Get-XmlAttribute -Node $selectedList -Name "comment"
Write-Output "Changelist: $name ($id)"
if ($comment) {
    Write-Output "Comment: $comment"
}
Write-Output "Path count: $($paths.Count)"
$paths | ForEach-Object { Write-Output $_ }

if ($paths.Count -gt 0) {
    $statusArgs = @("status", "--short", "--") + $paths.ToArray()
    $status = Invoke-Git -RepoRoot $repoRoot -Args $statusArgs -AllowFailure
    if ($status.Output) {
        Write-Output ""
        Write-Output "Git status for selected paths:"
        $status.Output | ForEach-Object { Write-Output $_ }
    }
}

if ($DryRun) {
    exit 0
}

if ($paths.Count -eq 0) {
    exit 2
}

if (-not $Message -or $Message.Count -eq 0) {
    Write-Error "Commit message is required. Pass -Message."
    exit 1
}

$selectedPathsAreAlreadyIndexed = Test-RealIndexMatchesWorktree -RepoRoot $repoRoot -Paths $paths.ToArray()

$tempIndexDir = Join-Path ([System.IO.Path]::GetTempPath()) ("jetbrains-changelist-index-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempIndexDir | Out-Null
$tempIndex = Join-Path $tempIndexDir "index"

try {
    if (Test-HasHead -RepoRoot $repoRoot) {
        Invoke-Git -RepoRoot $repoRoot -Args @("read-tree", "HEAD") -IndexFile $tempIndex | Out-Null
    }
    else {
        Invoke-Git -RepoRoot $repoRoot -Args @("read-tree", "--empty") -IndexFile $tempIndex | Out-Null
    }

    $addArgs = @("add", "-A", "--") + $paths.ToArray()
    Invoke-Git -RepoRoot $repoRoot -Args $addArgs -IndexFile $tempIndex | Out-Null

    $diffArgs = @("diff", "--cached", "--quiet", "--") + $paths.ToArray()
    $diff = Invoke-Git -RepoRoot $repoRoot -Args $diffArgs -IndexFile $tempIndex -AllowFailure
    if ($diff.Code -eq 0) {
        Write-Error "Selected changelist has no staged changes to commit"
        exit 1
    }
    if ($diff.Code -ne 1) {
        exit $diff.Code
    }

    $commitArgs = @("commit")
    if ($NoVerify) {
        $commitArgs += "--no-verify"
    }
    foreach ($item in $Message) {
        $commitArgs += @("-m", $item)
    }

    $commit = Invoke-Git -RepoRoot $repoRoot -Args $commitArgs -IndexFile $tempIndex
    $commit.Output | ForEach-Object { Write-Output $_ }
}
finally {
    Remove-Item -LiteralPath $tempIndexDir -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not $selectedPathsAreAlreadyIndexed) {
    $addArgs = @("add", "-A", "--") + $paths.ToArray()
    Invoke-Git -RepoRoot $repoRoot -Args $addArgs | Out-Null
}

$rev = Invoke-Git -RepoRoot $repoRoot -Args @("rev-parse", "--short", "HEAD")
Write-Output ""
Write-Output "Committed: $($rev.Output.Trim())"
