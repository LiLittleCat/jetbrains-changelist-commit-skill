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

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

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

function Quote-ProcessArgument {
    param([string]$Value)

    if ($Value.Length -eq 0) {
        return '""'
    }
    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Invoke-GitBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string[]]$Args,
        [switch]$AllowFailure
    )

    $git = Get-Command git -ErrorAction Stop
    $allArgs = @("-C", $RepoRoot) + $Args
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $git.Source
    $startInfo.Arguments = (($allArgs | ForEach-Object { Quote-ProcessArgument $_ }) -join " ")
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()

    $stdout = New-Object System.IO.MemoryStream
    $process.StandardOutput.BaseStream.CopyTo($stdout)
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($process.ExitCode -ne 0 -and -not $AllowFailure) {
        if ($stderr) {
            Write-Error $stderr
        }
        exit $process.ExitCode
    }

    [pscustomobject]@{
        Code = $process.ExitCode
        Bytes = $stdout.ToArray()
        Error = $stderr
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

function Split-ByteLines {
    param([byte[]]$Bytes)

    $lines = New-Object System.Collections.Generic.List[byte[]]
    $start = 0
    for ($i = 0; $i -lt $Bytes.Length; $i++) {
        if ($Bytes[$i] -eq 10) {
            $length = $i - $start + 1
            $line = New-Object byte[] $length
            [System.Array]::Copy($Bytes, $start, $line, 0, $length)
            $lines.Add($line)
            $start = $i + 1
        }
    }
    if ($start -lt $Bytes.Length) {
        $length = $Bytes.Length - $start
        $line = New-Object byte[] $length
        [System.Array]::Copy($Bytes, $start, $line, 0, $length)
        $lines.Add($line)
    }
    return $lines
}

function Join-ByteLines {
    param([System.Collections.IEnumerable]$Lines)

    $stream = New-Object System.IO.MemoryStream
    foreach ($line in $Lines) {
        $stream.Write($line, 0, $line.Length)
    }
    return $stream.ToArray()
}

function Get-HeadBlobBytes {
    param(
        [string]$RepoRoot,
        [string]$Path
    )

    if (-not (Test-HasHead -RepoRoot $RepoRoot)) {
        return [byte[]]@()
    }

    $result = Invoke-GitBytes -RepoRoot $RepoRoot -Args @("show", "HEAD:$Path") -AllowFailure
    if ($result.Code -eq 0) {
        return $result.Bytes
    }
    return [byte[]]@()
}

function Convert-LineRangesToBytes {
    param(
        [byte[]]$BaseBytes,
        [byte[]]$WorktreeBytes,
        [object[]]$Ranges,
        [string]$Path
    )

    $baseLines = @(Split-ByteLines -Bytes $BaseBytes)
    $worktreeLines = @(Split-ByteLines -Bytes $WorktreeBytes)
    $selected = New-Object System.Collections.Generic.List[byte[]]
    $cursor = 0

    foreach ($range in ($Ranges | Sort-Object Start1, Start2, End1, End2)) {
        if ($range.Start1 -lt $cursor) {
            throw "Overlapping line ranges for $Path"
        }
        if ($range.End1 -gt $baseLines.Count -or $range.End2 -gt $worktreeLines.Count) {
            throw "Line range is outside file bounds for $Path"
        }
        for ($i = $cursor; $i -lt $range.Start1; $i++) {
            $selected.Add($baseLines[$i])
        }
        for ($i = $range.Start2; $i -lt $range.End2; $i++) {
            $selected.Add($worktreeLines[$i])
        }
        $cursor = $range.End1
    }

    for ($i = $cursor; $i -lt $baseLines.Count; $i++) {
        $selected.Add($baseLines[$i])
    }
    return Join-ByteLines -Lines $selected
}

function Get-IndexMode {
    param(
        [string]$RepoRoot,
        [string]$Path,
        [string]$IndexFile
    )

    $result = Invoke-Git -RepoRoot $RepoRoot -Args @("ls-files", "-s", "--", $Path) -IndexFile $IndexFile -AllowFailure
    if ($result.Code -ne 0) {
        exit $result.Code
    }
    if ($result.Output) {
        return (($result.Output | Select-Object -First 1) -split "\s+")[0]
    }
    return "100644"
}

function New-PartialIndexEntries {
    param(
        [string]$RepoRoot,
        [hashtable]$PartialRanges,
        [string]$IndexFile,
        [string]$TempDir
    )

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($path in $PartialRanges.Keys) {
        $worktreePath = Join-Path $RepoRoot ($path.Replace("/", [System.IO.Path]::DirectorySeparatorChar))
        $worktreeBytes = if (Test-Path -LiteralPath $worktreePath) {
            [System.IO.File]::ReadAllBytes($worktreePath)
        } else {
            [byte[]]@()
        }
        $content = Convert-LineRangesToBytes `
            -BaseBytes (Get-HeadBlobBytes -RepoRoot $RepoRoot -Path $path) `
            -WorktreeBytes $worktreeBytes `
            -Ranges @($PartialRanges[$path]) `
            -Path $path

        $contentFile = Join-Path $TempDir ([System.Guid]::NewGuid().ToString("N"))
        [System.IO.File]::WriteAllBytes($contentFile, $content)
        $hashResult = Invoke-Git -RepoRoot $RepoRoot -Args @("hash-object", "-w", "--path=$path", $contentFile)
        $oid = ($hashResult.Output | Where-Object { $_.ToString() -match '^[0-9a-f]{40,64}$' } | Select-Object -First 1).ToString().Trim()
        if (-not $oid) {
            throw "Failed to hash selected content for $path"
        }
        $mode = Get-IndexMode -RepoRoot $RepoRoot -Path $path -IndexFile $IndexFile
        $entries.Add([pscustomobject]@{
            Path = $path
            Mode = $mode
            Oid = $oid
        })
    }
    return $entries
}

function Update-IndexEntries {
    param(
        [string]$RepoRoot,
        [object[]]$Entries,
        [string]$IndexFile
    )

    foreach ($entry in $Entries) {
        Invoke-Git `
            -RepoRoot $RepoRoot `
            -Args @("update-index", "--add", "--cacheinfo", $entry.Mode, $entry.Oid, $entry.Path) `
            -IndexFile $IndexFile | Out-Null
    }
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
$partialRanges = @{}

if ($id) {
    $lineComponent = $xml.SelectSingleNode("//component[@name='LineStatusTrackerManager']")
    if ($null -ne $lineComponent) {
        foreach ($fileNode in @($lineComponent.SelectNodes("file"))) {
            $rawPath = Get-XmlAttribute -Node $fileNode -Name "path"
            if ([string]::IsNullOrWhiteSpace($rawPath)) {
                continue
            }
            $relative = ConvertTo-RepoRelativePath -RawPath $rawPath -RepoRoot $repoRoot
            if (-not $seen.Contains($relative)) {
                continue
            }

            $ranges = New-Object System.Collections.Generic.List[object]
            foreach ($rangeNode in @($fileNode.SelectNodes("ranges/range"))) {
                if ((Get-XmlAttribute -Node $rangeNode -Name "changelist") -ne $id) {
                    continue
                }
                $range = [pscustomobject]@{
                    Start1 = [int](Get-XmlAttribute -Node $rangeNode -Name "start1")
                    End1 = [int](Get-XmlAttribute -Node $rangeNode -Name "end1")
                    Start2 = [int](Get-XmlAttribute -Node $rangeNode -Name "start2")
                    End2 = [int](Get-XmlAttribute -Node $rangeNode -Name "end2")
                }
                if ($range.Start1 -lt 0 -or $range.End1 -lt $range.Start1 -or
                    $range.Start2 -lt 0 -or $range.End2 -lt $range.Start2) {
                    throw "Invalid line range bounds for $relative"
                }
                $ranges.Add($range)
            }
            if ($ranges.Count -gt 0) {
                $partialRanges[$relative] = $ranges.ToArray()
            }
        }
    }
}

Write-Output "Changelist: $name ($id)"
if ($comment) {
    Write-Output "Comment: $comment"
}
Write-Output "Path count: $($paths.Count)"
$paths | ForEach-Object { Write-Output $_ }

if ($partialRanges.Count -gt 0) {
    Write-Output ""
    Write-Output "Line ranges:"
    foreach ($path in $paths) {
        if (-not $partialRanges.ContainsKey($path)) {
            continue
        }
        Write-Output $path
        foreach ($range in $partialRanges[$path]) {
            Write-Output "  old $($range.Start1):$($range.End1) -> new $($range.Start2):$($range.End2)"
        }
    }
}

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
    $listLabel = if ($name) { $name } elseif ($id) { $id } else { "<unnamed>" }
    Write-Error "No files to commit from changelist '$listLabel'. Nothing was committed."
    exit 2
}

if (-not $Message -or $Message.Count -eq 0) {
    Write-Error "Commit message is required. Pass -Message."
    exit 1
}

$partialPathSet = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($path in $partialRanges.Keys) {
    [void]$partialPathSet.Add($path)
}

$fullPaths = New-Object System.Collections.Generic.List[string]
foreach ($path in $paths) {
    if (-not $partialPathSet.Contains($path)) {
        $fullPaths.Add($path)
    }
}

$fullPathsAreAlreadyIndexed = $true
if ($fullPaths.Count -gt 0) {
    $fullPathsAreAlreadyIndexed = Test-RealIndexMatchesWorktree -RepoRoot $repoRoot -Paths $fullPaths.ToArray()
}

$partialEntries = @()
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

    if ($fullPaths.Count -gt 0) {
        $addArgs = @("add", "-A", "--") + $fullPaths.ToArray()
        Invoke-Git -RepoRoot $repoRoot -Args $addArgs -IndexFile $tempIndex | Out-Null
    }

    if ($partialRanges.Count -gt 0) {
        $partialEntries = @(New-PartialIndexEntries `
            -RepoRoot $repoRoot `
            -PartialRanges $partialRanges `
            -IndexFile $tempIndex `
            -TempDir $tempIndexDir)
        Update-IndexEntries -RepoRoot $repoRoot -Entries $partialEntries -IndexFile $tempIndex
    }

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

if ($fullPaths.Count -gt 0 -and -not $fullPathsAreAlreadyIndexed) {
    $addArgs = @("add", "-A", "--") + $fullPaths.ToArray()
    Invoke-Git -RepoRoot $repoRoot -Args $addArgs | Out-Null
}

if ($partialEntries.Count -gt 0) {
    Update-IndexEntries -RepoRoot $repoRoot -Entries $partialEntries
}

$rev = Invoke-Git -RepoRoot $repoRoot -Args @("rev-parse", "--short", "HEAD")
Write-Output ""
$revText = ($rev.Output | Select-Object -First 1).ToString().Trim()
Write-Output "Committed: $revText"
