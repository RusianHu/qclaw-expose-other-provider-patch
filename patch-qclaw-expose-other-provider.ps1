param(
    [string]$InstallRoot = '',
    [string]$ExpectedDisplayVersion = '0.1.13',
    [switch]$AllowUnknownVersion,
    [switch]$DryRun,
    [switch]$Unpatch,
    [switch]$Restore,
    [string]$RestoreFrom = '',
    [switch]$PrintDetectedRoot,
    [switch]$Status
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) {
    Write-Host ('[QClawPatch] ' + $msg) -ForegroundColor Cyan
}

function Write-WarnMsg($msg) {
    Write-Host ('[QClawPatch] ' + $msg) -ForegroundColor Yellow
}

function Find-Bytes([byte[]]$haystack, [byte[]]$needle, [int]$startIndex = 0) {
    for ($i = $startIndex; $i -le $haystack.Length - $needle.Length; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $needle.Length; $j++) {
            if ($haystack[$i + $j] -ne $needle[$j]) { $ok = $false; break }
        }
        if ($ok) { return $i }
    }
    return -1
}

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-InstallTag([string]$root) {
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw '安装目录为空，无法生成目录标签。'
    }
    $normalized = [System.IO.Path]::GetFullPath($root).TrimEnd('\').ToLowerInvariant()
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normalized))
    } finally {
        if ($sha256) { $sha256.Dispose() }
    }
    return (-join ($hash[0..7] | ForEach-Object { $_.ToString('x2') }))
}

function Get-ScopedBackupCandidates([string]$directory, [string]$installTag) {
    return @(
        Get-ChildItem -LiteralPath $directory -Filter ('app.asar.' + $installTag + '.*.bak') -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
    )
}

function New-ReplacedBytes([byte[]]$source, [int]$offset, [byte[]]$replacement) {
    [byte[]]$result = New-Object byte[] ($source.Length)
    [Array]::Copy($source, $result, $source.Length)
    [Array]::Copy($replacement, 0, $result, $offset, $replacement.Length)
    return $result
}

function Stop-QClawProcess {
    Write-Step '停止 QClaw 进程'
    Stop-Process -Name 'QClaw' -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

function Test-QClawInstallRoot([string]$root) {
    if ([string]::IsNullOrWhiteSpace($root)) { return $null }
    try {
        $fullRoot = [System.IO.Path]::GetFullPath($root)
    } catch {
        return $null
    }
    $exePath = Join-Path $fullRoot 'QClaw.exe'
    $asarPath = Join-Path $fullRoot 'resources\app.asar'
    if ((Test-Path -LiteralPath $exePath) -and (Test-Path -LiteralPath $asarPath)) {
        return [pscustomobject]@{
            Root = $fullRoot
            ExePath = $exePath
            AsarPath = $asarPath
        }
    }
    return $null
}

function Add-Candidate([System.Collections.Generic.List[string]]$list, [string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return }
    try {
        $full = [System.IO.Path]::GetFullPath($value)
    } catch {
        return
    }
    if (-not $list.Contains($full)) {
        $list.Add($full)
    }
}

function Get-RegistryInstallCandidates {
    $result = New-Object 'System.Collections.Generic.List[string]'
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($path in $paths) {
        try {
            $items = Get-ItemProperty -Path $path -ErrorAction Stop
        } catch {
            continue
        }
        foreach ($item in $items) {
            $displayName = [string]$item.DisplayName
            if ($displayName -and $displayName -notmatch 'QClaw') { continue }
            if ($item.InstallLocation) {
                Add-Candidate $result ([string]$item.InstallLocation)
            }
            foreach ($field in @('DisplayIcon','UninstallString','QuietUninstallString')) {
                $raw = [string]($item.$field)
                if ([string]::IsNullOrWhiteSpace($raw)) { continue }
                if ($raw -match '([A-Za-z]:\\[^\"]*?QClaw\\QClaw\.exe)') {
                    Add-Candidate $result (Split-Path -Parent $matches[1])
                    continue
                }
                if ($raw -match '([A-Za-z]:\\[^\"]*?QClaw\\)') {
                    Add-Candidate $result ($matches[1])
                }
            }
        }
    }
    return $result
}

function Resolve-QClawInstall {
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    if ($InstallRoot) {
        Add-Candidate $candidates $InstallRoot
    }

    try {
        $proc = Get-Process -Name 'QClaw' -ErrorAction Stop | Select-Object -First 1
        if ($proc -and $proc.Path) {
            Add-Candidate $candidates (Split-Path -Parent $proc.Path)
        }
    } catch {}

    foreach ($candidate in (Get-RegistryInstallCandidates)) {
        Add-Candidate $candidates $candidate
    }

    foreach ($candidate in @(
        (Join-Path $env:ProgramFiles 'QClaw'),
        (Join-Path ${env:ProgramFiles(x86)} 'QClaw'),
        (Join-Path $env:LOCALAPPDATA 'Programs\QClaw'),
        (Join-Path $env:LOCALAPPDATA 'QClaw'),
        (Join-Path $env:USERPROFILE 'AppData\Local\Programs\QClaw')
    )) {
        Add-Candidate $candidates $candidate
    }

    $valid = @()
    foreach ($candidate in $candidates) {
        $test = Test-QClawInstallRoot $candidate
        if ($test) { $valid += $test }
    }

    if ($valid.Count -eq 0) {
        $msg = "未自动识别到 QClaw 安装目录。已尝试候选：`n - " + (($candidates | Select-Object -Unique) -join "`n - ") + "`n可手动指定 -InstallRoot。"
        throw $msg
    }

    if ($valid.Count -gt 1) {
        Write-Step ('发现多个有效安装目录，默认使用第一个：' + $valid[0].Root)
        foreach ($item in $valid) {
            Write-Host ('  CANDIDATE=' + $item.Root) -ForegroundColor DarkGray
        }
    }

    return $valid[0]
}

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$patchDir = Join-Path $scriptRoot 'QClawPatches'
New-Item -ItemType Directory -Force -Path $patchDir | Out-Null

$isAdmin = Test-IsAdministrator
$readOnlyMode = ($Status -or $DryRun -or $PrintDetectedRoot)
Write-Step ('管理员终端=' + ($(if ($isAdmin) { 'YES' } else { 'NO' })))
if (-not $isAdmin) {
    if ($readOnlyMode) {
        Write-WarnMsg '当前不是管理员终端：只读模式可继续，写入模式会被拒绝。'
    } else {
        throw '当前终端不是管理员。正式补丁、反修补与回滚会写入 Program Files，请改用“管理员 PowerShell”重试；若只想探测，可使用 -Status / -DryRun / -PrintDetectedRoot。'
    }
}

$selectedActions = @()
if ($Restore) { $selectedActions += 'Restore' }
if ($Unpatch) { $selectedActions += 'Unpatch' }
if ($selectedActions.Count -gt 1) {
    throw '参数冲突：-Restore 与 -Unpatch 不能同时使用。'
}
if ($RestoreFrom -and -not $Restore) {
    throw '参数错误：-RestoreFrom 只能与 -Restore 一起使用。'
}

$resolved = Resolve-QClawInstall
$exePath = $resolved.ExePath
$asarPath = $resolved.AsarPath
$resolvedRoot = $resolved.Root
$installTag = Get-InstallTag $resolvedRoot

Write-Step ('安装目录=' + $resolvedRoot)
Write-Step ('安装目录标签=' + $installTag)

if ($PrintDetectedRoot) {
    Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
    exit 0
}

$searchText = 'key:"doubao",label:"豆包"'
$replaceText = 'key:"other",label: "其他"'
$guardText = 'if(v.value==="other"){if(!g.value)return void We.warning("请输入 Base URL");if(!m.value)return void We.warning("请输入模型名称")}'

$search = [System.Text.Encoding]::UTF8.GetBytes($searchText)
$replace = [System.Text.Encoding]::UTF8.GetBytes($replaceText)
$guard = [System.Text.Encoding]::UTF8.GetBytes($guardText)

if ($search.Length -ne $replace.Length) {
    throw "内部错误：替换串长度不一致 [$($search.Length)] vs [$($replace.Length)]"
}

if ($Restore) {
    if (-not $RestoreFrom) {
        $scopedCandidates = Get-ScopedBackupCandidates $patchDir $installTag
        if ($scopedCandidates.Count -gt 0) {
            $RestoreFrom = $scopedCandidates[0].FullName
            Write-Step ('未显式指定 -RestoreFrom，自动选择当前安装目录的最近备份=' + $RestoreFrom)
        } else {
            $legacyCandidates = @(
                Get-ChildItem -LiteralPath $patchDir -Filter 'app.asar.*.bak' -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending
            )
            if ($legacyCandidates.Count -eq 1) {
                $RestoreFrom = $legacyCandidates[0].FullName
                Write-WarnMsg ('未找到当前安装目录标签匹配的备份，自动回退到唯一 legacy 备份=' + $RestoreFrom)
            } elseif ($legacyCandidates.Count -gt 1) {
                throw '未找到与当前安装目录标签匹配的备份，且存在多个 legacy 备份。为避免误回滚，请显式使用 -RestoreFrom 指定。'
            } else {
                throw '未找到可回滚的备份文件，请使用 -RestoreFrom 指定。'
            }
        }
    }

    if (!(Test-Path -LiteralPath $RestoreFrom)) {
        throw "回滚备份不存在: $RestoreFrom"
    }

    [byte[]]$restoreBytes = [System.IO.File]::ReadAllBytes($RestoreFrom)
    $restorePosSearch = Find-Bytes $restoreBytes $search 0
    $restorePosSearch2 = if ($restorePosSearch -ge 0) { Find-Bytes $restoreBytes $search ($restorePosSearch + 1) } else { -1 }
    $restorePosReplace = Find-Bytes $restoreBytes $replace 0
    $restorePosReplace2 = if ($restorePosReplace -ge 0) { Find-Bytes $restoreBytes $replace ($restorePosReplace + 1) } else { -1 }
    $restorePosGuard = Find-Bytes $restoreBytes $guard 0

    if ($restorePosGuard -lt 0) {
        throw '回滚备份校验失败：未命中 other 分支保护特征，拒绝写回。'
    }

    $restoreLooksOriginal = ($restorePosSearch -ge 0 -and $restorePosSearch2 -lt 0 -and $restorePosReplace -lt 0)
    $restoreLooksPatched = ($restorePosReplace -ge 0 -and $restorePosReplace2 -lt 0 -and $restorePosSearch -lt 0)
    if (-not ($restoreLooksOriginal -or $restoreLooksPatched)) {
        throw '回滚备份校验失败：备份文件未通过特征一致性检查，拒绝写回。'
    }

    if ($DryRun) {
        Write-Host 'DRY_RUN_OK' -ForegroundColor Green
        Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
        Write-Host ('WOULD_RESTORE_FROM=' + $RestoreFrom)
        Write-Host ('WOULD_WRITE_TO=' + $asarPath)
        exit 0
    }

    Stop-QClawProcess
    Copy-Item -LiteralPath $RestoreFrom -Destination $asarPath -Force

    $restoredHash = (Get-FileHash -LiteralPath $asarPath -Algorithm SHA256).Hash
    $restoreHash = (Get-FileHash -LiteralPath $RestoreFrom -Algorithm SHA256).Hash
    if ($restoredHash -ne $restoreHash) {
        throw '回滚校验失败：目标文件哈希与备份不一致。'
    }

    Write-Host 'RESTORE_OK' -ForegroundColor Green
    Write-Host ('RESTORED_FROM=' + $RestoreFrom)
    Write-Host ('TARGET=' + $asarPath)
    Write-Host ('SHA256=' + $restoredHash)
    exit 0
}

$fv = (Get-Item -LiteralPath $exePath).VersionInfo.FileVersion
$pv = (Get-Item -LiteralPath $exePath).VersionInfo.ProductVersion
Write-Step ('检测版本 FileVersion=' + $fv + ' ProductVersion=' + $pv)
if (-not $AllowUnknownVersion) {
    $versionOk = $false
    if ($fv -and $fv -like ('*' + $ExpectedDisplayVersion + '*')) { $versionOk = $true }
    if ($pv -and $pv -like ('*' + $ExpectedDisplayVersion + '*')) { $versionOk = $true }
    if (-not $versionOk) {
        throw "版本校验失败：当前版本与预期 [$ExpectedDisplayVersion] 不匹配。可用 -AllowUnknownVersion 跳过版本限制。"
    }
}

[byte[]]$bytes = [System.IO.File]::ReadAllBytes($asarPath)
$posSearch = Find-Bytes $bytes $search 0
$posSearch2 = if ($posSearch -ge 0) { Find-Bytes $bytes $search ($posSearch + 1) } else { -1 }
$posReplace = Find-Bytes $bytes $replace 0
$posReplace2 = if ($posReplace -ge 0) { Find-Bytes $bytes $replace ($posReplace + 1) } else { -1 }
$posGuard = Find-Bytes $bytes $guard 0

if ($Status) {
    if ($posGuard -lt 0) {
        Write-Host 'STATUS=UNSUPPORTED_BUILD' -ForegroundColor Red
        Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
        Write-Host ('APP_ASAR=' + $asarPath)
        Write-Host ('DETAIL=missing_other_guard')
        exit 2
    }
    if ($posSearch2 -ge 0) {
        Write-Host 'STATUS=AMBIGUOUS' -ForegroundColor Red
        Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
        Write-Host ('APP_ASAR=' + $asarPath)
        Write-Host ('DETAIL=multiple_search_hits')
        Write-Host ('SEARCH_OFFSET_1=' + $posSearch)
        Write-Host ('SEARCH_OFFSET_2=' + $posSearch2)
        exit 3
    }
    if ($posReplace2 -ge 0) {
        Write-Host 'STATUS=AMBIGUOUS' -ForegroundColor Red
        Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
        Write-Host ('APP_ASAR=' + $asarPath)
        Write-Host ('DETAIL=multiple_replace_hits')
        Write-Host ('REPLACE_OFFSET_1=' + $posReplace)
        Write-Host ('REPLACE_OFFSET_2=' + $posReplace2)
        exit 3
    }
    if ($posReplace -ge 0 -and $posSearch -lt 0) {
        Write-Host 'STATUS=PATCHED_OR_OPEN' -ForegroundColor Green
        Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
        Write-Host ('APP_ASAR=' + $asarPath)
        Write-Host ('PATCH_OFFSET=' + $posReplace)
        exit 0
    }
    if ($posSearch -ge 0 -and $posReplace -lt 0) {
        Write-Host 'STATUS=UNPATCHED_PATCHABLE' -ForegroundColor Yellow
        Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
        Write-Host ('APP_ASAR=' + $asarPath)
        Write-Host ('SEARCH_OFFSET=' + $posSearch)
        exit 0
    }
    Write-Host 'STATUS=UNKNOWN' -ForegroundColor Red
    Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
    Write-Host ('APP_ASAR=' + $asarPath)
    Write-Host ('DETAIL=mixed_or_feature_mismatch')
    exit 4
}

if ($Unpatch) {
    if ($posGuard -lt 0) {
        throw '特征校验失败：未找到自定义 other 分支逻辑，拒绝反修补。'
    }
    if ($posReplace2 -ge 0) {
        throw "安全校验失败：已补丁定位串出现多次 [$posReplace, $posReplace2]，拒绝反修补。"
    }
    if ($posSearch2 -ge 0) {
        throw "安全校验失败：原始定位串出现多次 [$posSearch, $posSearch2]，拒绝反修补。"
    }
    if ($posSearch -ge 0 -and $posReplace -lt 0) {
        Write-Host 'ALREADY_UNPATCHED' -ForegroundColor Yellow
        Write-Host ('APP_ASAR=' + $asarPath)
        Write-Host ('SEARCH_OFFSET=' + $posSearch)
        exit 0
    }
    if ($posReplace -lt 0) {
        throw '特征校验失败：未找到已补丁 other 槽位，拒绝反修补。'
    }
    if ($posSearch -ge 0) {
        throw '特征校验失败：检测到原始 doubao 与已补丁 other 特征同时存在，状态混杂，拒绝反修补。'
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $patchDir ('app.asar.' + $installTag + '.' + $timestamp + '.bak')
    $unpatchedCopy = Join-Path $patchDir ('app.asar.' + $installTag + '.' + $timestamp + '.unpatched')

    Write-Step ('命中偏移 replace=' + $posReplace + ' guard=' + $posGuard)
    Write-Step ('备份将保存到 ' + $backup)
    Write-Step ('unpatched 副本将保存到 ' + $unpatchedCopy)

    [byte[]]$unpatched = New-ReplacedBytes $bytes $posReplace $search
    [System.IO.File]::WriteAllBytes($unpatchedCopy, $unpatched)

    $verifyUnpatched = [System.IO.File]::ReadAllBytes($unpatchedCopy)
    $verifySearchPos = Find-Bytes $verifyUnpatched $search 0
    $verifyReplacePos = Find-Bytes $verifyUnpatched $replace 0
    if ($verifySearchPos -lt 0 -or $verifyReplacePos -ge 0) {
        throw 'unpatched 副本校验失败：未恢复到原始 doubao 特征。'
    }

    if ($DryRun) {
        Write-Host 'DRY_RUN_OK' -ForegroundColor Green
        Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
        Write-Host ('UNPATCHED_COPY=' + $unpatchedCopy)
        Write-Host ('WOULD_BACKUP_TO=' + $backup)
        exit 0
    }

    Stop-QClawProcess
    Copy-Item -LiteralPath $asarPath -Destination $backup -Force
    [System.IO.File]::WriteAllBytes($asarPath, $unpatched)

    $targetHash = (Get-FileHash -LiteralPath $asarPath -Algorithm SHA256).Hash
    $unpatchedHash = (Get-FileHash -LiteralPath $unpatchedCopy -Algorithm SHA256).Hash
    if ($targetHash -ne $unpatchedHash) {
        throw '反修补写回校验失败：目标文件哈希与 unpatched 副本不一致。'
    }

    Write-Host 'UNPATCH_OK' -ForegroundColor Green
    Write-Host ('TARGET=' + $asarPath)
    Write-Host ('BACKUP=' + $backup)
    Write-Host ('UNPATCHED_COPY=' + $unpatchedCopy)
    Write-Host ('SHA256=' + $targetHash)
    exit 0
}

if ($posGuard -lt 0) {
    throw '特征校验失败：未找到自定义 other 分支逻辑，拒绝补丁。'
}
if ($posReplace2 -ge 0) {
    throw "安全校验失败：已补丁定位串出现多次 [$posReplace, $posReplace2]，拒绝补丁。"
}
if ($posSearch2 -ge 0) {
    throw "安全校验失败：原始定位串出现多次 [$posSearch, $posSearch2]，拒绝补丁。"
}
if ($posReplace -ge 0 -and $posSearch -lt 0) {
    Write-Host 'ALREADY_PATCHED' -ForegroundColor Yellow
    Write-Host ('APP_ASAR=' + $asarPath)
    Write-Host ('PATCH_OFFSET=' + $posReplace)
    exit 0
}
if ($posSearch -lt 0) {
    throw '特征校验失败：未找到原始 doubao 槽位，拒绝补丁。'
}
if ($posReplace -ge 0) {
    throw '特征校验失败：检测到原始 doubao 与已补丁 other 特征同时存在，状态混杂，拒绝补丁。'
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $patchDir ('app.asar.' + $installTag + '.' + $timestamp + '.bak')
$patchedCopy = Join-Path $patchDir ('app.asar.' + $installTag + '.' + $timestamp + '.patched')

Write-Step ('命中偏移 search=' + $posSearch + ' guard=' + $posGuard)
Write-Step ('备份将保存到 ' + $backup)
Write-Step ('patched 副本将保存到 ' + $patchedCopy)

[byte[]]$patched = New-ReplacedBytes $bytes $posSearch $replace
[System.IO.File]::WriteAllBytes($patchedCopy, $patched)

$verifyPatched = [System.IO.File]::ReadAllBytes($patchedCopy)
$verifyPos = Find-Bytes $verifyPatched $replace 0
$verifySearchPos = Find-Bytes $verifyPatched $search 0
if ($verifyPos -lt 0 -or $verifySearchPos -ge 0) {
    throw 'patched 副本校验失败：未写入唯一目标特征。'
}

if ($DryRun) {
    Write-Host 'DRY_RUN_OK' -ForegroundColor Green
    Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
    Write-Host ('PATCHED_COPY=' + $patchedCopy)
    Write-Host ('WOULD_BACKUP_TO=' + $backup)
    exit 0
}

Stop-QClawProcess
Copy-Item -LiteralPath $asarPath -Destination $backup -Force
[System.IO.File]::WriteAllBytes($asarPath, $patched)

$targetHash = (Get-FileHash -LiteralPath $asarPath -Algorithm SHA256).Hash
$patchedHash = (Get-FileHash -LiteralPath $patchedCopy -Algorithm SHA256).Hash
if ($targetHash -ne $patchedHash) {
    throw '写回校验失败：目标文件哈希与 patched 副本不一致。'
}

Write-Host 'PATCH_OK' -ForegroundColor Green
Write-Host ('TARGET=' + $asarPath)
Write-Host ('BACKUP=' + $backup)
Write-Host ('PATCHED_COPY=' + $patchedCopy)
Write-Host ('SHA256=' + $targetHash)
