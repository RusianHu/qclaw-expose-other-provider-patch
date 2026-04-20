param(
    [string]$InstallRoot = '',
    [string]$ExpectedDisplayVersion = '0.2.10',
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

function Write-LegacyPatchResidueHint {
    Write-WarnMsg '若之前用旧版本脚本修补过，随后又升级了 QClaw，旧残留可能导致失败、状态异常或运行异常；可先重新安装 QClaw（https://qclaw.qq.com/），再使用管理员 PowerShell 重新运行脚本。'
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

function Find-FirstTextMatch([byte[]]$haystack, [string[]]$texts) {
    foreach ($text in $texts) {
        $needle = [System.Text.Encoding]::UTF8.GetBytes($text)
        $pos = Find-Bytes $haystack $needle 0
        if ($pos -ge 0) {
            return [pscustomobject]@{
                Text = $text
                Position = $pos
            }
        }
    }
    return $null
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

function Get-TextHitCount([string]$haystack, [string]$needle) {
    if ([string]::IsNullOrEmpty($needle)) {
        return 0
    }

    $count = 0
    $startIndex = 0
    while ($true) {
        $pos = $haystack.IndexOf($needle, $startIndex, [System.StringComparison]::Ordinal)
        if ($pos -lt 0) { break }
        $count++
        $startIndex = $pos + $needle.Length
    }
    return $count
}

function Get-OneLineText([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ''
    }
    return ([regex]::Replace($text, '\s+', ' ').Trim())
}

function Get-NormalizedNpmVersion([string]$versionSpec, [string]$fallbackVersion) {
    if ($versionSpec -match '(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)') {
        return $matches[1]
    }
    return $fallbackVersion
}

function New-ReplaceSpec([string]$name, [string]$searchText, [string]$replaceText) {
    $searchBytes = [System.Text.Encoding]::UTF8.GetBytes($searchText)
    $replaceBytes = [System.Text.Encoding]::UTF8.GetBytes($replaceText)
    if ($searchBytes.Length -ne $replaceBytes.Length) {
        throw ("内部错误：替换串长度不一致 [" + $name + "] [" + $searchBytes.Length + "] vs [" + $replaceBytes.Length + "]")
    }
    return [pscustomobject]@{
        Name = $name
        SearchText = $searchText
        ReplaceText = $replaceText
        SearchBytes = $searchBytes
        ReplaceBytes = $replaceBytes
    }
}

function Get-ReplaceSpecMatchState([byte[]]$haystack, [object[]]$specs) {
    $searchHits = @()
    $replaceHits = @()

    foreach ($spec in $specs) {
        $posSearch = Find-Bytes $haystack $spec.SearchBytes 0
        while ($posSearch -ge 0) {
            $searchHits += [pscustomobject]@{
                Position = $posSearch
                VariantName = $spec.Name
                Spec = $spec
            }
            $posSearch = Find-Bytes $haystack $spec.SearchBytes ($posSearch + 1)
        }

        $posReplace = Find-Bytes $haystack $spec.ReplaceBytes 0
        while ($posReplace -ge 0) {
            $replaceHits += [pscustomobject]@{
                Position = $posReplace
                VariantName = $spec.Name
                Spec = $spec
            }
            $posReplace = Find-Bytes $haystack $spec.ReplaceBytes ($posReplace + 1)
        }
    }

    $searchHits = @($searchHits | Sort-Object Position, VariantName)
    $replaceHits = @($replaceHits | Sort-Object Position, VariantName)

    $mode = if ($searchHits.Count -gt 1 -or $replaceHits.Count -gt 1) {
        'AMBIGUOUS'
    } elseif ($searchHits.Count -eq 1 -and $replaceHits.Count -eq 0) {
        'PATCH'
    } elseif ($replaceHits.Count -eq 1 -and $searchHits.Count -eq 0) {
        'ALREADY_FIXED'
    } elseif ($searchHits.Count -eq 0 -and $replaceHits.Count -eq 0) {
        'SKIP_FEATURE'
    } else {
        'MIXED'
    }

    $selectedSpec = $null
    if ($searchHits.Count -eq 1) {
        $selectedSpec = $searchHits[0].Spec
    } elseif ($replaceHits.Count -eq 1) {
        $selectedSpec = $replaceHits[0].Spec
    } elseif ($specs.Count -gt 0) {
        $selectedSpec = $specs[0]
    }

    $searchPosition = if ($searchHits.Count -ge 1) { $searchHits[0].Position } else { -1 }
    $searchPosition2 = if ($searchHits.Count -ge 2) { $searchHits[1].Position } else { -1 }
    $replacePosition = if ($replaceHits.Count -ge 1) { $replaceHits[0].Position } else { -1 }
    $replacePosition2 = if ($replaceHits.Count -ge 2) { $replaceHits[1].Position } else { -1 }
    $selectedVariant = if ($selectedSpec) { $selectedSpec.Name } else { '' }
    $selectedSearchBytes = if ($selectedSpec) { $selectedSpec.SearchBytes } else { $null }
    $selectedReplaceBytes = if ($selectedSpec) { $selectedSpec.ReplaceBytes } else { $null }

    return [pscustomobject]@{
        Mode = $mode
        SearchPosition = $searchPosition
        SearchPosition2 = $searchPosition2
        ReplacePosition = $replacePosition
        ReplacePosition2 = $replacePosition2
        SelectedSpec = $selectedSpec
        SelectedVariant = $selectedVariant
        SelectedSearchBytes = $selectedSearchBytes
        SelectedReplaceBytes = $selectedReplaceBytes
    }
}

function Test-SharpImport([string]$openClawRoot) {
    $script = "import('sharp').then(m=>{const s=m.default??m; console.log('SHARP_IMPORT_OK', typeof s);}).catch(err=>{console.error('ERRCODE=' + ((err&&err.code)?err.code:'UNKNOWN')); console.error('ERRMSG=' + ((err&&err.message)?err.message:String(err))); process.exit(1);})"
    $output = ''
    $exitCode = 0

    Push-Location $openClawRoot
    try {
        $output = (& node -e $script 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    if ($exitCode -eq 0) {
        return [pscustomobject]@{
            Success = $true
            Code = 'sharp_import_ok'
            Message = 'sharp_import_ok'
        }
    }

    $normalizedOutput = Get-OneLineText $output
    $errorCode = if ($normalizedOutput -match 'ERRCODE=([A-Za-z0-9_]+)') {
        $matches[1].ToLowerInvariant()
    } else {
        'import_failed'
    }

    return [pscustomobject]@{
        Success = $false
        Code = $errorCode
        Message = $normalizedOutput
    }
}

function Get-SharpFixState([string]$installRoot) {
    $openClawRoot = Join-Path $installRoot 'resources\openclaw'
    $packageJsonPath = Join-Path $openClawRoot 'package.json'
    $moduleDirectory = Join-Path $openClawRoot 'node_modules\sharp'
    $state = [ordered]@{
        InstallRoot = $installRoot
        OpenClawRoot = $openClawRoot
        PackageJsonPath = $packageJsonPath
        ModuleDirectory = $moduleDirectory
        OpenClawExists = (Test-Path -LiteralPath $openClawRoot)
        PackageJsonExists = (Test-Path -LiteralPath $packageJsonPath)
        ModuleDirectoryExists = (Test-Path -LiteralPath $moduleDirectory)
        PackageDeclared = $false
        DeclaredVersion = $null
        TargetVersion = $sharpFallbackVersion
        NodeAvailable = $false
        NpmAvailable = $false
        ImportCheckAttempted = $false
        ImportOk = $false
        RequiresFix = $false
        State = 'SKIP_NO_OPENCLAW'
        Detail = 'openclaw_root_missing'
        ImportMessage = ''
    }

    if (-not $state.OpenClawExists) {
        return [pscustomobject]$state
    }

    if (-not $state.PackageJsonExists) {
        $state.State = 'SKIP_NO_PACKAGE_JSON'
        $state.Detail = 'package_json_missing'
        return [pscustomobject]$state
    }

    try {
        $packageJson = [System.IO.File]::ReadAllText($packageJsonPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        $state.State = 'SKIP_INVALID_PACKAGE_JSON'
        $state.Detail = 'package_json_parse_failed'
        $state.ImportMessage = (Get-OneLineText $_.Exception.Message)
        return [pscustomobject]$state
    }

    $sharpVersionSpec = [string]$packageJson.dependencies.sharp
    if ([string]::IsNullOrWhiteSpace($sharpVersionSpec)) {
        $sharpVersionSpec = [string]$packageJson.optionalDependencies.sharp
    }
    if ([string]::IsNullOrWhiteSpace($sharpVersionSpec)) {
        $state.State = 'SKIP_NOT_DECLARED'
        $state.Detail = 'sharp_not_declared'
        return [pscustomobject]$state
    }

    $state.PackageDeclared = $true
    $state.DeclaredVersion = $sharpVersionSpec
    $state.TargetVersion = Get-NormalizedNpmVersion $sharpVersionSpec $sharpFallbackVersion
    $state.NodeAvailable = ($null -ne (Get-Command node -ErrorAction SilentlyContinue))
    $state.NpmAvailable = ($null -ne (Get-Command npm -ErrorAction SilentlyContinue))

    if (-not $state.NodeAvailable) {
        $state.State = 'SKIP_NO_NODE'
        $state.Detail = 'node_not_found'
        return [pscustomobject]$state
    }

    $state.ImportCheckAttempted = $true
    $importState = Test-SharpImport $openClawRoot
    $state.ImportOk = $importState.Success
    $state.ImportMessage = $importState.Message
    if ($importState.Success) {
        $state.State = 'OK'
        $state.Detail = 'sharp_import_ok'
        return [pscustomobject]$state
    }

    if (-not $state.NpmAvailable) {
        $state.State = 'BROKEN_NO_NPM'
        $state.Detail = 'npm_not_found'
        return [pscustomobject]$state
    }

    $state.RequiresFix = $true
    $state.State = 'REPAIR_REQUIRED'
    $state.Detail = $importState.Code
    return [pscustomobject]$state
}

function Invoke-SharpRepair([psobject]$state) {
    if (-not $state.RequiresFix) {
        return $state
    }
    if (-not $state.NodeAvailable) {
        throw 'sharp 自修复失败：未找到 node，无法执行导入校验。'
    }
    if (-not $state.NpmAvailable) {
        throw 'sharp 自修复失败：未找到 npm，无法安装 sharp。'
    }

    Write-Step ('执行 sharp 运行时自修复 version=' + $state.TargetVersion)
    Write-Step ('sharp 工作目录=' + $state.OpenClawRoot)

    Push-Location $state.OpenClawRoot
    try {
        & npm install ('sharp@' + $state.TargetVersion) '--no-save' '--package-lock=false' '--omit=dev' '--legacy-peer-deps' ('--registry=' + $sharpInstallRegistry)
        if ($LASTEXITCODE -ne 0) {
            throw ('npm install sharp 失败，退出码=' + $LASTEXITCODE)
        }
    } finally {
        Pop-Location
    }

    $updatedState = Get-SharpFixState $state.InstallRoot
    if (-not $updatedState.ImportOk) {
        throw ('sharp 自修复后校验失败：state=' + $updatedState.State + ' detail=' + $updatedState.Detail)
    }
    return $updatedState
}

function Write-SharpStateSummary([psobject]$state) {
    if (-not $state) {
        return
    }

    Write-Host ('SHARP_STATE=' + $state.State)
    Write-Host ('SHARP_DETAIL=' + $state.Detail)
    if ($state.TargetVersion) {
        Write-Host ('SHARP_VERSION=' + $state.TargetVersion)
    }
    if ($state.OpenClawRoot) {
        Write-Host ('SHARP_OPENCLAW_ROOT=' + $state.OpenClawRoot)
    }
    if ($state.ImportCheckAttempted) {
        Write-Host ('SHARP_IMPORT_OK=' + ($(if ($state.ImportOk) { 'YES' } else { 'NO' })))
    }
    Write-Host ('SHARP_MODULE_DIR=' + ($(if ($state.ModuleDirectoryExists) { 'YES' } else { 'NO' })))
}

function Resolve-SkillHubRegexFixTargetFile([string]$installRoot) {
    foreach ($relativePath in $skillHubRegexFixRelativePaths) {
        $candidate = Join-Path $installRoot $relativePath
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return (Join-Path $installRoot $skillHubRegexFixRelativePaths[0])
}

function Get-SkillHubRegexFixState([string]$installRoot, [string]$fileVersion, [string]$productVersion, [bool]$allowUnknownVersion) {
    $targetFile = Resolve-SkillHubRegexFixTargetFile $installRoot

    $versionEligible = $false
    foreach ($version in $skillHubRegexFixSupportedVersions) {
        if (($fileVersion -and $fileVersion -like ('*' + $version + '*')) -or ($productVersion -and $productVersion -like ('*' + $version + '*'))) {
            $versionEligible = $true
            break
        }
    }

    $fixAllowed = ($versionEligible -or $allowUnknownVersion)
    if (!(Test-Path -LiteralPath $targetFile)) {
        return [pscustomobject]@{
            FilePath = $targetFile
            Exists = $false
            VersionEligible = $versionEligible
            FixAllowed = $fixAllowed
            FeatureRecognized = $false
            RequiresFix = $false
            AlreadyFixed = $false
            Content = $null
        }
    }

    $content = [System.IO.File]::ReadAllText($targetFile)
    $legacyRuntimeHits = Get-TextHitCount $content $skillHubRegexFixLegacyRuntimePattern
    $patchedRuntimeHits = Get-TextHitCount $content $skillHubRegexFixPatchedRuntimePattern
    $legacySchemaHits = Get-TextHitCount $content $skillHubRegexFixLegacySchemaPattern
    $transitionalSchemaHits = Get-TextHitCount $content $skillHubRegexFixTransitionalSchemaPattern
    $patchedSchemaHits = Get-TextHitCount $content $skillHubRegexFixPatchedSchemaPattern

    $featureRecognized = (($legacyRuntimeHits + $patchedRuntimeHits) -eq 1 -and ($legacySchemaHits + $transitionalSchemaHits + $patchedSchemaHits) -eq 1)
    $alreadyFixed = ($legacyRuntimeHits -eq 0 -and $patchedRuntimeHits -eq 1 -and $legacySchemaHits -eq 0 -and $transitionalSchemaHits -eq 0 -and $patchedSchemaHits -eq 1)
    $requiresFix = ($featureRecognized -and ($patchedRuntimeHits -ne 1 -or $patchedSchemaHits -ne 1))

    return [pscustomobject]@{
        FilePath = $targetFile
        Exists = $true
        VersionEligible = $versionEligible
        FixAllowed = $fixAllowed
        FeatureRecognized = $featureRecognized
        RequiresFix = $requiresFix
        AlreadyFixed = $alreadyFixed
        Content = $content
        LegacyRuntimeHits = $legacyRuntimeHits
        PatchedRuntimeHits = $patchedRuntimeHits
        LegacySchemaHits = $legacySchemaHits
        TransitionalSchemaHits = $transitionalSchemaHits
        PatchedSchemaHits = $patchedSchemaHits
    }
}

function New-SkillHubRegexFixedContent([psobject]$state) {
    if (-not $state.Exists) {
        throw 'skillhub-installer.ts 不存在，无法生成修补内容。'
    }
    if (-not $state.FeatureRecognized) {
        throw 'skillhub-installer.ts 未命中兼容特征，拒绝生成修补内容。'
    }

    $updated = [string]$state.Content
    $updated = $updated.Replace($skillHubRegexFixLegacyRuntimePattern, $skillHubRegexFixPatchedRuntimePattern)
    $updated = $updated.Replace($skillHubRegexFixLegacySchemaPattern, $skillHubRegexFixPatchedSchemaPattern)
    $updated = $updated.Replace($skillHubRegexFixTransitionalSchemaPattern, $skillHubRegexFixPatchedSchemaPattern)
    return $updated
}

function New-ReplacedBytes([byte[]]$source, [int]$offset, [byte[]]$replacement) {
    [byte[]]$result = New-Object byte[] ($source.Length)
    [Array]::Copy($source, $result, $source.Length)
    [Array]::Copy($replacement, 0, $result, $offset, $replacement.Length)
    return $result
}

function Get-Sha256Hex([byte[]]$data) {
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash($data)
    } finally {
        if ($sha256) { $sha256.Dispose() }
    }
    return (-join ($hash | ForEach-Object { $_.ToString('x2') }))
}

function Get-AsarDataOffset([int]$headerLength) {
    return 16 + (4 * [int][Math]::Ceiling($headerLength / 4.0))
}

function Get-AsarHeaderInfo([byte[]]$bytes) {
    if ($bytes.Length -lt 16) {
        throw 'ASAR 文件过小，无法读取头部。'
    }

    $headerLength = [int][BitConverter]::ToUInt32($bytes, 12)
    if ($headerLength -le 0) {
        throw 'ASAR 头部长度无效。'
    }
    if ($bytes.Length -lt (16 + $headerLength)) {
        throw 'ASAR 文件不完整：头部长度超出文件范围。'
    }

    return [pscustomobject]@{
        Length = $headerLength
        Json = [System.Text.Encoding]::UTF8.GetString($bytes, 16, $headerLength)
        DataOffset = Get-AsarDataOffset $headerLength
    }
}

function Find-AsarFileEntryByOffsetRecursive([System.Collections.IDictionary]$node, [string]$prefix, [long]$targetOffset, [int]$dataOffset) {
    if (-not $node.Contains('files')) {
        return $null
    }

    $files = $node['files']
    foreach ($name in $files.Keys) {
        $child = $files[$name]
        $path = if ($prefix) { $prefix + '/' + [string]$name } else { [string]$name }

        if ($child -is [System.Collections.IDictionary] -and $child.Contains('files')) {
            $nested = Find-AsarFileEntryByOffsetRecursive $child $path $targetOffset $dataOffset
            if ($nested) {
                return $nested
            }
            continue
        }

        if ($child -is [System.Collections.IDictionary] -and $child.Contains('offset') -and $child.Contains('size')) {
            [long]$start = [long]$dataOffset + [long]$child['offset']
            [long]$size = [long]$child['size']
            [long]$end = $start + $size
            if ($targetOffset -ge $start -and $targetOffset -lt $end) {
                return [pscustomobject]@{
                    Path = $path
                    Entry = $child
                    Start = $start
                    Size = $size
                    End = $end
                }
            }
        }
    }

    return $null
}

function Get-AsarIntegrityStateForOffset([byte[]]$bytes, [int]$targetOffset) {
    $headerInfo = Get-AsarHeaderInfo $bytes
    $headerObject = $headerInfo.Json | ConvertFrom-Json -AsHashtable
    $entryInfo = Find-AsarFileEntryByOffsetRecursive $headerObject '' $targetOffset $headerInfo.DataOffset
    if (-not $entryInfo) {
        throw ('ASAR 头部中未找到覆盖偏移 [' + $targetOffset + '] 的文件条目。')
    }

    $entry = $entryInfo.Entry
    if (-not $entry.Contains('integrity')) {
        throw ('ASAR 文件条目缺少 integrity 信息：' + $entryInfo.Path)
    }

    $integrity = $entry['integrity']
    $algorithm = [string]$integrity['algorithm']
    if ($algorithm -and $algorithm.ToUpperInvariant() -ne 'SHA256') {
        throw ('ASAR 文件条目使用了不支持的完整性算法 [' + $algorithm + ']：' + $entryInfo.Path)
    }

    $blockSize = [int]$integrity['blockSize']
    if ($blockSize -le 0) {
        throw ('ASAR 文件条目的 blockSize 无效：' + $entryInfo.Path)
    }
    if ($entryInfo.Size -gt [int]::MaxValue) {
        throw ('ASAR 文件条目体积过大，当前脚本不支持：' + $entryInfo.Path)
    }

    [byte[]]$fileBytes = New-Object byte[] ([int]$entryInfo.Size)
    [Array]::Copy($bytes, [int]$entryInfo.Start, $fileBytes, 0, [int]$entryInfo.Size)

    $fileHash = Get-Sha256Hex $fileBytes
    $actualBlockHashes = New-Object 'System.Collections.Generic.List[string]'
    for ($blockOffset = 0; $blockOffset -lt $fileBytes.Length; $blockOffset += $blockSize) {
        $currentBlockLength = [Math]::Min($blockSize, $fileBytes.Length - $blockOffset)
        [byte[]]$blockBytes = New-Object byte[] $currentBlockLength
        [Array]::Copy($fileBytes, $blockOffset, $blockBytes, 0, $currentBlockLength)
        $actualBlockHashes.Add((Get-Sha256Hex $blockBytes))
    }

    $expectedFileHash = [string]$integrity['hash']
    $expectedFileHashNormalized = if ($expectedFileHash) { $expectedFileHash.ToLowerInvariant() } else { '' }
    $expectedBlockHashes = @($integrity['blocks'])
    $actualBlockHashesArray = @($actualBlockHashes.ToArray())

    $blocksMatch = ($expectedBlockHashes.Count -eq $actualBlockHashesArray.Count)
    if ($blocksMatch) {
        for ($i = 0; $i -lt $expectedBlockHashes.Count; $i++) {
            $expectedBlockHash = [string]$expectedBlockHashes[$i]
            if ($expectedBlockHash.ToLowerInvariant() -cne $actualBlockHashesArray[$i]) {
                $blocksMatch = $false
                break
            }
        }
    }

    return [pscustomobject]@{
        HeaderLength = $headerInfo.Length
        HeaderJson = $headerInfo.Json
        HeaderObject = $headerObject
        DataOffset = $headerInfo.DataOffset
        Path = $entryInfo.Path
        Entry = $entry
        Integrity = $integrity
        Start = $entryInfo.Start
        Size = $entryInfo.Size
        BlockSize = $blockSize
        FileHash = $fileHash
        BlockHashes = $actualBlockHashesArray
        ExpectedFileHash = $expectedFileHashNormalized
        ExpectedBlockHashes = $expectedBlockHashes
        IntegrityMatch = (($expectedFileHashNormalized -ceq $fileHash) -and $blocksMatch)
    }
}

function Get-AsarRawHeaderHash([byte[]]$bytes) {
    $headerInfo = Get-AsarHeaderInfo $bytes
    return Get-Sha256Hex ([System.Text.Encoding]::UTF8.GetBytes($headerInfo.Json))
}

function Update-AsarIntegrityForModifiedOffset([byte[]]$bytes, [int]$modifiedOffset) {
    $integrityState = Get-AsarIntegrityStateForOffset $bytes $modifiedOffset
    $expectedBlockHashes = @($integrityState.ExpectedBlockHashes)
    if ($expectedBlockHashes.Count -ne $integrityState.BlockHashes.Count) {
        throw ('ASAR 完整性块数量发生变化，当前补丁策略无法安全更新头部：' + $integrityState.Path)
    }

    $integrityState.Integrity['hash'] = $integrityState.FileHash
    for ($i = 0; $i -lt $integrityState.BlockHashes.Count; $i++) {
        $expectedBlockHashes[$i] = $integrityState.BlockHashes[$i]
    }
    $integrityState.Integrity['blocks'] = $expectedBlockHashes

    $updatedHeaderJson = $integrityState.HeaderObject | ConvertTo-Json -Depth 100 -Compress
    if ($updatedHeaderJson.Length -ne $integrityState.HeaderLength) {
        throw ('ASAR 头部长度发生变化 [' + $integrityState.HeaderLength + ' -> ' + $updatedHeaderJson.Length + ']，拒绝写回。')
    }

    $updatedHeaderBytes = [System.Text.Encoding]::UTF8.GetBytes($updatedHeaderJson)
    [byte[]]$result = New-Object byte[] ($bytes.Length)
    [Array]::Copy($bytes, $result, $bytes.Length)
    [Array]::Copy($updatedHeaderBytes, 0, $result, 16, $updatedHeaderBytes.Length)

    $verifyState = Get-AsarIntegrityStateForOffset $result $modifiedOffset
    if (-not $verifyState.IntegrityMatch) {
        throw ('ASAR 头部完整性回写后复核失败：' + $verifyState.Path)
    }

    return [pscustomobject]@{
        Bytes = $result
        HeaderHash = Get-Sha256Hex $updatedHeaderBytes
        TargetPath = $verifyState.Path
        TargetFileHash = $verifyState.FileHash
        BlockSize = $verifyState.BlockSize
        BlockCount = $verifyState.BlockHashes.Count
    }
}

function Ensure-QClawResourceApi {
    if (([System.Management.Automation.PSTypeName]'Win32.QClawResourceApi').Type) {
        return
    }

    $source = @"
using System;
using System.Runtime.InteropServices;
namespace Win32 {
    public static class QClawResourceApi {
        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        public static extern IntPtr LoadLibraryEx(string lpLibFileName, IntPtr hFile, uint dwFlags);

        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool FreeLibrary(IntPtr hModule);

        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        public static extern IntPtr FindResourceEx(IntPtr hModule, string lpType, string lpName, ushort wLanguage);

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern uint SizeofResource(IntPtr hModule, IntPtr hResInfo);

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern IntPtr LoadResource(IntPtr hModule, IntPtr hResInfo);

        [DllImport("kernel32.dll")]
        public static extern IntPtr LockResource(IntPtr hResData);

        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        public static extern IntPtr BeginUpdateResource(string pFileName, [MarshalAs(UnmanagedType.Bool)] bool bDeleteExistingResources);

        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool UpdateResource(IntPtr hUpdate, string lpType, string lpName, ushort wLanguage, byte[] lpData, uint cbData);

        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool EndUpdateResource(IntPtr hUpdate, [MarshalAs(UnmanagedType.Bool)] bool fDiscard);
    }
}
"@
    Add-Type -TypeDefinition $source
}

function Get-LastWin32ErrorMessage {
    $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    return ([ComponentModel.Win32Exception]::new($code).Message + ' [' + $code + ']')
}

function Get-EmbeddedAsarIntegrityConfig([string]$exeFile) {
    Ensure-QClawResourceApi

    $module = [Win32.QClawResourceApi]::LoadLibraryEx($exeFile, [IntPtr]::Zero, 2)
    if ($module -eq [IntPtr]::Zero) {
        throw ('读取 EXE 内嵌 ASAR 完整性资源失败：LoadLibraryEx 失败 - ' + (Get-LastWin32ErrorMessage))
    }

    try {
        $resourceInfo = [IntPtr]::Zero
        foreach ($lang in @([UInt16]1033, [UInt16]0)) {
            $resourceInfo = [Win32.QClawResourceApi]::FindResourceEx($module, 'INTEGRITY', 'ELECTRONASAR', $lang)
            if ($resourceInfo -ne [IntPtr]::Zero) {
                break
            }
        }
        if ($resourceInfo -eq [IntPtr]::Zero) {
            throw ('读取 EXE 内嵌 ASAR 完整性资源失败：FindResourceEx 失败 - ' + (Get-LastWin32ErrorMessage))
        }

        $resourceSize = [Win32.QClawResourceApi]::SizeofResource($module, $resourceInfo)
        if ($resourceSize -le 0) {
            throw ('读取 EXE 内嵌 ASAR 完整性资源失败：SizeofResource 失败 - ' + (Get-LastWin32ErrorMessage))
        }

        $loadedResource = [Win32.QClawResourceApi]::LoadResource($module, $resourceInfo)
        if ($loadedResource -eq [IntPtr]::Zero) {
            throw ('读取 EXE 内嵌 ASAR 完整性资源失败：LoadResource 失败 - ' + (Get-LastWin32ErrorMessage))
        }

        $resourcePointer = [Win32.QClawResourceApi]::LockResource($loadedResource)
        if ($resourcePointer -eq [IntPtr]::Zero) {
            throw '读取 EXE 内嵌 ASAR 完整性资源失败：LockResource 返回空指针。'
        }

        [byte[]]$buffer = New-Object byte[] ([int]$resourceSize)
        [Runtime.InteropServices.Marshal]::Copy($resourcePointer, $buffer, 0, [int]$resourceSize)
        return [System.Text.Encoding]::UTF8.GetString($buffer)
    } finally {
        [Win32.QClawResourceApi]::FreeLibrary($module) | Out-Null
    }
}

function New-EmbeddedAsarIntegrityConfigJson([string]$headerHash) {
    if ($headerHash -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'EXE 内嵌 ASAR 头部哈希格式无效。'
    }
    return ('[{"file":"resources\\app.asar","alg":"sha256","value":"' + $headerHash.ToLowerInvariant() + '"}]')
}

function Get-EmbeddedAsarHeaderHash([string]$exeFile) {
    $config = Get-EmbeddedAsarIntegrityConfig $exeFile
    if ($config -match '"value":"([0-9a-fA-F]{64})"') {
        return $matches[1].ToLowerInvariant()
    }
    throw 'EXE 内嵌 ASAR 完整性资源格式无效：未找到 64 位 sha256 value。'
}

function Set-EmbeddedAsarHeaderHash([string]$exeFile, [string]$headerHash) {
    Ensure-QClawResourceApi

    $config = New-EmbeddedAsarIntegrityConfigJson $headerHash
    $updateHandle = [Win32.QClawResourceApi]::BeginUpdateResource($exeFile, $false)
    if ($updateHandle -eq [IntPtr]::Zero) {
        throw ('写入 EXE 内嵌 ASAR 完整性资源失败：BeginUpdateResource 失败 - ' + (Get-LastWin32ErrorMessage))
    }

    $committed = $false
    try {
        $configBytes = [System.Text.Encoding]::UTF8.GetBytes($config)
        if (-not [Win32.QClawResourceApi]::UpdateResource($updateHandle, 'INTEGRITY', 'ELECTRONASAR', [UInt16]1033, $configBytes, [uint32]$configBytes.Length)) {
            throw ('写入 EXE 内嵌 ASAR 完整性资源失败：UpdateResource 失败 - ' + (Get-LastWin32ErrorMessage))
        }
        if (-not [Win32.QClawResourceApi]::EndUpdateResource($updateHandle, $false)) {
            throw ('写入 EXE 内嵌 ASAR 完整性资源失败：EndUpdateResource 失败 - ' + (Get-LastWin32ErrorMessage))
        }
        $committed = $true
    } finally {
        if (-not $committed) {
            [void][Win32.QClawResourceApi]::EndUpdateResource($updateHandle, $true)
        }
    }
}

function Write-AsarAndSyncEmbeddedIntegrity([string]$asarFile, [string]$exeFile, [byte[]]$targetBytes, [string]$targetHeaderHash, [byte[]]$rollbackBytes, [string]$rollbackHeaderHash, [string]$actionLabel) {
    $expectedFileHash = Get-Sha256Hex $targetBytes
    $normalizedTargetHeaderHash = $targetHeaderHash.ToLowerInvariant()

    try {
        [System.IO.File]::WriteAllBytes($asarFile, $targetBytes)
        Set-EmbeddedAsarHeaderHash $exeFile $normalizedTargetHeaderHash

        $writtenFileHash = (Get-FileHash -LiteralPath $asarFile -Algorithm SHA256).Hash
        if ($writtenFileHash.ToLowerInvariant() -cne $expectedFileHash) {
            throw ($actionLabel + ' 写回校验失败：目标文件哈希与预期不一致。')
        }

        $writtenEmbeddedHeaderHash = Get-EmbeddedAsarHeaderHash $exeFile
        if ($writtenEmbeddedHeaderHash -cne $normalizedTargetHeaderHash) {
            throw ($actionLabel + ' 写回校验失败：EXE 内嵌 ASAR 头部哈希与预期不一致。')
        }

        return [pscustomobject]@{
            AsarHash = $writtenFileHash
            EmbeddedHeaderHash = $writtenEmbeddedHeaderHash
        }
    } catch {
        if ($rollbackBytes) {
            try {
                [System.IO.File]::WriteAllBytes($asarFile, $rollbackBytes)
            } catch {
                Write-WarnMsg ($actionLabel + ' 失败后恢复 app.asar 失败：' + $_.Exception.Message)
            }
        }
        if ($rollbackHeaderHash) {
            try {
                Set-EmbeddedAsarHeaderHash $exeFile $rollbackHeaderHash
            } catch {
                Write-WarnMsg ($actionLabel + ' 失败后恢复 EXE 内嵌 ASAR 头部哈希失败：' + $_.Exception.Message)
            }
        }
        throw
    }
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

$searchText = 'key:"doubao",label:"火山引擎（豆包）"'
$replaceTextCore = 'key:"other",label:"其他"'
$replacePaddingLength = [System.Text.Encoding]::UTF8.GetByteCount($searchText) - [System.Text.Encoding]::UTF8.GetByteCount($replaceTextCore)
if ($replacePaddingLength -lt 0) {
    throw '内部错误：provider 槽位替换串长度超过原始槽位长度，无法执行等长原位替换。'
}
$replaceText = $replaceTextCore + (' ' * $replacePaddingLength)
$remoteOverrideSpecs = @(
    (New-ReplaceSpec 'QClaw 0.2.4 modelApi' 't.data&&t.data.length>0&&(Eo=t.data,hu(Eo,"modelApi"))' 't.data&&t.data.length<0&&(Eo=t.data,hu(Eo,"modelApi"))'),
    (New-ReplaceSpec 'QClaw 0.2.5 modelApi' 't.data&&t.data.length>0&&(Ko=t.data,Ru(Ko,"modelApi"))' 't.data&&t.data.length<0&&(Ko=t.data,Ru(Ko,"modelApi"))'),
    (New-ReplaceSpec 'QClaw 0.2.10 modelApi' 't.data&&t.data.length>0&&(To=t.data,p0(To,"modelApi"))' 't.data&&t.data.length<0&&(To=t.data,p0(To,"modelApi"))')
)
$guardTexts = @(
    'if(f.value==="other"){if(!g.value)return void Xe.warning("请输入 Base URL");if(!h.value)return void Xe.warning("请输入模型名称")}else if(!m.value)return void Xe.warning("请选择或输入模型名称")}',
    'if(v.value==="other"){if(!g.value)return void We.warning("请输入 Base URL");if(!m.value)return void We.warning("请输入模型名称")}',
    'if(v.value==="other"){if(!h.value)return void ze.warning("请输入 Base URL");if(!m.value)return void ze.warning("请输入模型名称")}else if(!w.value)return void ze.warning("请选择或输入模型名称")}',
    'if(v.value==="other"){if(!g.value)return void Ze.warning("请输入 Base URL");if(!h.value)return void Ze.warning("请输入模型名称")}else if(!m.value)return void Ze.warning("请选择或输入模型名称")}',
    'if(f.value==="other"){if(!m.value)return void We.warning("请输入 Base URL");if(!g.value)return void We.warning("请输入模型名称")}else if(!h.value)return void We.warning("请选择或输入模型名称")}',
    'if(f.value==="other"){if(!g.value)return void Ge.warning("请输入 Base URL");if(!h.value)return void Ge.warning("请输入模型名称")}else if(!m.value)return void Ge.warning("请选择或输入模型名称")}',
    'if(f.value==="other"){if(!v.value)return void qe.warning("请输入 Base URL");if(!g.value)return void qe.warning("请输入模型名称")}else if(!h.value)return void qe.warning("请选择或输入模型名称")}',
    'if(s.value==="custom"){if(!v.value)return void Je.warning("请选择模型厂商");if(v.value!==Sn){if(!m.value)return void Je.warning("请输入 API Key");if(v.value==="other"){if(!p.value)return void Je.warning("请输入 Base URL");if(!g.value)return void Je.warning("请输入模型名称")}else if(!h.value)return void Je.warning("请选择或输入模型名称")}}',
    'if(d.value==="custom"){if(!f.value)return void lt.warning("请选择模型厂商");if(f.value!==yl){if(!v.value)return void lt.warning("请输入 API Key");if(f.value==="other"){if(!h.value)return void lt.warning("请输入 Base URL");if(!m.value)return void lt.warning("请输入模型名称")}else if(!g.value)return void lt.warning("请选择或输入模型名称")}}'
)
$skillHubRegexFixRelativePaths = @(
    'resources\openclaw\config\extensions\qclaw-plugin\packages\content-plugin\src\skillhub-installer.ts',
    'resources\openclaw\config\extensions\content-plugin\src\skillhub-installer.ts'
)
$skillHubRegexFixSupportedVersions = @('0.1.19', '0.1.20', '0.1.22', '0.2.1', '0.2.4', '0.2.5', '0.2.10')
$skillHubRegexFixLegacyRuntimePattern = 'const SKILL_NAME_PATTERN = /^[\p{L}\p{N}_\-\.]{1,128}$/u;'
$skillHubRegexFixPatchedRuntimePattern = 'const SKILL_NAME_PATTERN = /^[A-Za-z0-9_.-]{1,128}$/;'
$skillHubRegexFixLegacySchemaPattern = 'pattern: "^[\\w\\-\\.\\p{L}]{1,128}$",'
$skillHubRegexFixTransitionalSchemaPattern = 'pattern: "^[\\w\\-\\.]{1,128}$",'
$skillHubRegexFixPatchedSchemaPattern = 'pattern: "^[A-Za-z0-9_.-]{1,128}$",'
$sharpFallbackVersion = '0.34.5'
$sharpInstallRegistry = 'https://registry.npmmirror.com'

$search = [System.Text.Encoding]::UTF8.GetBytes($searchText)
$replace = [System.Text.Encoding]::UTF8.GetBytes($replaceText)

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
    $restoreGuardMatch = Find-FirstTextMatch $restoreBytes $guardTexts
    $restorePosGuard = if ($restoreGuardMatch) { $restoreGuardMatch.Position } else { -1 }

    if ($restorePosGuard -lt 0) {
        throw '回滚备份校验失败：未命中兼容的 other 分支保护特征，拒绝写回。'
    }

    $restoreLooksOriginal = ($restorePosSearch -ge 0 -and $restorePosSearch2 -lt 0 -and $restorePosReplace -lt 0)
    $restoreLooksPatched = ($restorePosReplace -ge 0 -and $restorePosReplace2 -lt 0 -and $restorePosSearch -lt 0)
    if (-not ($restoreLooksOriginal -or $restoreLooksPatched)) {
        throw '回滚备份校验失败：备份文件未通过特征一致性检查，拒绝写回。'
    }

    if ($restoreLooksOriginal) {
        $restoreIntegrityState = Get-AsarIntegrityStateForOffset $restoreBytes $restorePosSearch
        if (-not $restoreIntegrityState.IntegrityMatch) {
            throw '回滚备份校验失败：原始目标文件的 ASAR 完整性记录不一致，拒绝写回。'
        }
    }
    if ($restoreLooksPatched) {
        $restoreIntegrityState = Get-AsarIntegrityStateForOffset $restoreBytes $restorePosReplace
        if (-not $restoreIntegrityState.IntegrityMatch) {
            throw '回滚备份校验失败：已补丁目标文件的 ASAR 完整性记录不一致，拒绝写回。'
        }
    }

    $restoreHeaderHash = Get-AsarRawHeaderHash $restoreBytes

    if ($DryRun) {
        Write-Host 'DRY_RUN_OK' -ForegroundColor Green
        Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
        Write-Host ('WOULD_RESTORE_FROM=' + $RestoreFrom)
        Write-Host ('WOULD_WRITE_TO=' + $asarPath)
        Write-Host ('WOULD_UPDATE_EXE=' + $exePath)
        Write-Host ('WOULD_WRITE_HEADER_SHA256=' + $restoreHeaderHash)
        exit 0
    }

    [byte[]]$currentBytes = [System.IO.File]::ReadAllBytes($asarPath)
    $currentHeaderHash = Get-AsarRawHeaderHash $currentBytes

    Stop-QClawProcess
    $restoreResult = Write-AsarAndSyncEmbeddedIntegrity $asarPath $exePath $restoreBytes $restoreHeaderHash $currentBytes $currentHeaderHash '回滚'

    Write-Host 'RESTORE_OK' -ForegroundColor Green
    Write-Host ('RESTORED_FROM=' + $RestoreFrom)
    Write-Host ('TARGET=' + $asarPath)
    Write-Host ('EXE=' + $exePath)
    Write-Host ('SHA256=' + $restoreResult.AsarHash)
    Write-Host ('ASAR_HEADER_SHA256=' + $restoreResult.EmbeddedHeaderHash)
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

$sharpFixState = Get-SharpFixState $resolvedRoot
$sharpFixMode = if ($sharpFixState.RequiresFix) {
    'PATCH'
} elseif ($sharpFixState.ImportOk) {
    'ALREADY_OK'
} else {
    'SKIP'
}
if ($sharpFixState.State -like 'BROKEN*') {
    Write-WarnMsg ('sharp 运行时状态异常，当前无法自动修复：' + $sharpFixState.Detail)
} elseif ($sharpFixState.State -like 'SKIP_*') {
    Write-Step ('sharp 自修复已跳过：' + $sharpFixState.Detail)
} elseif ($sharpFixMode -eq 'PATCH') {
    Write-WarnMsg ('检测到 sharp 导入失败，将在写入流程中尝试自修复：' + $sharpFixState.Detail)
}

$skillHubFixState = Get-SkillHubRegexFixState $resolvedRoot $fv $pv ([bool]$AllowUnknownVersion)
if ($skillHubFixState.Exists -and $skillHubFixState.FixAllowed -and -not $skillHubFixState.FeatureRecognized) {
    Write-WarnMsg ('skillhub regex 修复未命中兼容特征，已跳过：' + $skillHubFixState.FilePath)
}
$skillHubFixMode = if (-not $skillHubFixState.Exists) {
    'MISSING'
} elseif (-not $skillHubFixState.FixAllowed) {
    'SKIP_VERSION'
} elseif (-not $skillHubFixState.FeatureRecognized) {
    'SKIP_FEATURE'
} elseif ($skillHubFixState.RequiresFix) {
    'PATCH'
} elseif ($skillHubFixState.AlreadyFixed) {
    'ALREADY_FIXED'
} else {
    'NOOP'
}

[byte[]]$bytes = [System.IO.File]::ReadAllBytes($asarPath)
$posSearch = Find-Bytes $bytes $search 0
$posSearch2 = if ($posSearch -ge 0) { Find-Bytes $bytes $search ($posSearch + 1) } else { -1 }
$posReplace = Find-Bytes $bytes $replace 0
$posReplace2 = if ($posReplace -ge 0) { Find-Bytes $bytes $replace ($posReplace + 1) } else { -1 }
$remoteOverrideState = Get-ReplaceSpecMatchState $bytes $remoteOverrideSpecs
$posRemoteSearch = $remoteOverrideState.SearchPosition
$posRemoteSearch2 = $remoteOverrideState.SearchPosition2
$posRemoteReplace = $remoteOverrideState.ReplacePosition
$posRemoteReplace2 = $remoteOverrideState.ReplacePosition2
$remoteOverrideFixMode = $remoteOverrideState.Mode
$remoteOverrideSearch = $remoteOverrideState.SelectedSearchBytes
$remoteOverrideReplace = $remoteOverrideState.SelectedReplaceBytes
$guardMatch = Find-FirstTextMatch $bytes $guardTexts
$posGuard = if ($guardMatch) { $guardMatch.Position } else { -1 }
$currentRawHeaderHash = Get-AsarRawHeaderHash $bytes
$currentEmbeddedHeaderHash = Get-EmbeddedAsarHeaderHash $exePath

if ($Status) {
    if ($posGuard -lt 0) {
        Write-LegacyPatchResidueHint
        Write-Host 'STATUS=UNSUPPORTED_BUILD' -ForegroundColor Red
        Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
        Write-Host ('APP_ASAR=' + $asarPath)
        Write-Host ('EXE=' + $exePath)
        Write-Host ('DETAIL=missing_other_guard')
        exit 2
    }
    if ($posSearch2 -ge 0) {
        Write-LegacyPatchResidueHint
        Write-Host 'STATUS=AMBIGUOUS' -ForegroundColor Red
        Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
        Write-Host ('APP_ASAR=' + $asarPath)
        Write-Host ('DETAIL=multiple_search_hits')
        Write-Host ('SEARCH_OFFSET_1=' + $posSearch)
        Write-Host ('SEARCH_OFFSET_2=' + $posSearch2)
        exit 3
    }
    if ($posReplace2 -ge 0) {
        Write-LegacyPatchResidueHint
        Write-Host 'STATUS=AMBIGUOUS' -ForegroundColor Red
        Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
        Write-Host ('APP_ASAR=' + $asarPath)
        Write-Host ('DETAIL=multiple_replace_hits')
        Write-Host ('REPLACE_OFFSET_1=' + $posReplace)
        Write-Host ('REPLACE_OFFSET_2=' + $posReplace2)
        exit 3
    }
    if ($remoteOverrideFixMode -eq 'AMBIGUOUS') {
        Write-LegacyPatchResidueHint
        Write-Host 'STATUS=AMBIGUOUS' -ForegroundColor Red
        Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
        Write-Host ('APP_ASAR=' + $asarPath)
        Write-Host ('EXE=' + $exePath)
        Write-Host ('DETAIL=multiple_remote_override_hits')
        if ($posRemoteSearch -ge 0) { Write-Host ('REMOTE_SEARCH_OFFSET_1=' + $posRemoteSearch) }
        if ($posRemoteSearch2 -ge 0) { Write-Host ('REMOTE_SEARCH_OFFSET_2=' + $posRemoteSearch2) }
        if ($posRemoteReplace -ge 0) { Write-Host ('REMOTE_REPLACE_OFFSET_1=' + $posRemoteReplace) }
        if ($posRemoteReplace2 -ge 0) { Write-Host ('REMOTE_REPLACE_OFFSET_2=' + $posRemoteReplace2) }
        exit 3
    }
    if ($remoteOverrideFixMode -eq 'MIXED') {
        Write-LegacyPatchResidueHint
        Write-Host 'STATUS=UNKNOWN' -ForegroundColor Red
        Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
        Write-Host ('APP_ASAR=' + $asarPath)
        Write-Host ('EXE=' + $exePath)
        Write-Host ('DETAIL=remote_override_mixed_state')
        Write-Host ('REMOTE_SEARCH_OFFSET=' + $posRemoteSearch)
        Write-Host ('REMOTE_REPLACE_OFFSET=' + $posRemoteReplace)
        exit 4
    }
    if ($currentEmbeddedHeaderHash -cne $currentRawHeaderHash) {
        Write-LegacyPatchResidueHint
        Write-Host 'STATUS=UNKNOWN' -ForegroundColor Red
        Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
        Write-Host ('APP_ASAR=' + $asarPath)
        Write-Host ('EXE=' + $exePath)
        Write-Host ('DETAIL=embedded_header_hash_mismatch')
        Write-Host ('EMBEDDED_HEADER_SHA256=' + $currentEmbeddedHeaderHash)
        Write-Host ('RAW_HEADER_SHA256=' + $currentRawHeaderHash)
        exit 4
    }
    if ($posReplace -ge 0 -and $posSearch -lt 0) {
        $replaceIntegrityState = Get-AsarIntegrityStateForOffset $bytes $posReplace
        if (-not $replaceIntegrityState.IntegrityMatch) {
            Write-LegacyPatchResidueHint
            Write-Host 'STATUS=UNKNOWN' -ForegroundColor Red
            Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
            Write-Host ('APP_ASAR=' + $asarPath)
            Write-Host ('EXE=' + $exePath)
            Write-Host ('DETAIL=patched_target_integrity_mismatch')
            Write-Host ('PATCH_OFFSET=' + $posReplace)
            Write-Host ('TARGET_PATH=' + $replaceIntegrityState.Path)
            exit 4
        }
        if ($remoteOverrideFixMode -eq 'PATCH') {
            Write-Host 'STATUS=PATCHED_NEEDS_REMOTE_OVERRIDE_FIX' -ForegroundColor Yellow
            Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
            Write-Host ('APP_ASAR=' + $asarPath)
            Write-Host ('EXE=' + $exePath)
            Write-Host ('PATCH_OFFSET=' + $posReplace)
            Write-Host ('REMOTE_OVERRIDE_SEARCH_OFFSET=' + $posRemoteSearch)
            Write-Host ('TARGET_PATH=' + $replaceIntegrityState.Path)
            Write-Host ('ASAR_HEADER_SHA256=' + $currentRawHeaderHash)
            Write-Host ('REMOTE_OVERRIDE_FIX=' + $remoteOverrideFixMode)
            Write-Host ('SHARP_FIX=' + $sharpFixMode)
            Write-SharpStateSummary $sharpFixState
            exit 0
        }
        Write-Host 'STATUS=PATCHED_OR_OPEN' -ForegroundColor Green
        Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
        Write-Host ('APP_ASAR=' + $asarPath)
        Write-Host ('EXE=' + $exePath)
        Write-Host ('PATCH_OFFSET=' + $posReplace)
        Write-Host ('TARGET_PATH=' + $replaceIntegrityState.Path)
        Write-Host ('ASAR_HEADER_SHA256=' + $currentRawHeaderHash)
        Write-Host ('REMOTE_OVERRIDE_FIX=' + $remoteOverrideFixMode)
        Write-Host ('SHARP_FIX=' + $sharpFixMode)
        Write-SharpStateSummary $sharpFixState
        exit 0
    }
    if ($posSearch -ge 0 -and $posReplace -lt 0) {
        $searchIntegrityState = Get-AsarIntegrityStateForOffset $bytes $posSearch
        if (-not $searchIntegrityState.IntegrityMatch) {
            Write-LegacyPatchResidueHint
            Write-Host 'STATUS=UNKNOWN' -ForegroundColor Red
            Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
            Write-Host ('APP_ASAR=' + $asarPath)
            Write-Host ('EXE=' + $exePath)
            Write-Host ('DETAIL=unpatched_target_integrity_mismatch')
            Write-Host ('SEARCH_OFFSET=' + $posSearch)
            Write-Host ('TARGET_PATH=' + $searchIntegrityState.Path)
            exit 4
        }
        Write-Host 'STATUS=UNPATCHED_PATCHABLE' -ForegroundColor Yellow
        Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
        Write-Host ('APP_ASAR=' + $asarPath)
        Write-Host ('EXE=' + $exePath)
        Write-Host ('SEARCH_OFFSET=' + $posSearch)
        Write-Host ('TARGET_PATH=' + $searchIntegrityState.Path)
        Write-Host ('ASAR_HEADER_SHA256=' + $currentRawHeaderHash)
        Write-Host ('REMOTE_OVERRIDE_FIX=' + $remoteOverrideFixMode)
        Write-Host ('SHARP_FIX=' + $sharpFixMode)
        Write-SharpStateSummary $sharpFixState
        exit 0
    }
    Write-LegacyPatchResidueHint
    Write-Host 'STATUS=UNKNOWN' -ForegroundColor Red
    Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
    Write-Host ('APP_ASAR=' + $asarPath)
    Write-Host ('EXE=' + $exePath)
    Write-Host ('DETAIL=mixed_or_feature_mismatch')
    Write-Host ('REMOTE_OVERRIDE_FIX=' + $remoteOverrideFixMode)
    exit 4
}

if ($Unpatch) {
    if ($posGuard -lt 0) {
        Write-LegacyPatchResidueHint
        throw '特征校验失败：未找到兼容的 other 分支逻辑，拒绝反修补。'
    }
    if ($posReplace2 -ge 0) {
        Write-LegacyPatchResidueHint
        throw "安全校验失败：已补丁定位串出现多次 [$posReplace, $posReplace2]，拒绝反修补。"
    }
    if ($posSearch2 -ge 0) {
        Write-LegacyPatchResidueHint
        throw "安全校验失败：原始定位串出现多次 [$posSearch, $posSearch2]，拒绝反修补。"
    }
    if ($remoteOverrideFixMode -eq 'AMBIGUOUS') {
        Write-LegacyPatchResidueHint
        throw '安全校验失败：modelApi 远端覆盖特征出现多次，拒绝反修补。'
    }
    if ($remoteOverrideFixMode -eq 'MIXED') {
        Write-LegacyPatchResidueHint
        throw '安全校验失败：modelApi 远端覆盖特征状态混杂，拒绝反修补。'
    }
    if ($posSearch -ge 0 -and $posReplace -lt 0 -and $remoteOverrideFixMode -ne 'ALREADY_FIXED') {
        $searchIntegrityState = Get-AsarIntegrityStateForOffset $bytes $posSearch
        Write-Host 'ALREADY_UNPATCHED' -ForegroundColor Yellow
        Write-Host ('APP_ASAR=' + $asarPath)
        Write-Host ('EXE=' + $exePath)
        Write-Host ('SEARCH_OFFSET=' + $posSearch)
        Write-Host ('TARGET_PATH=' + $searchIntegrityState.Path)
        Write-Host ('ASAR_HEADER_SHA256=' + $currentRawHeaderHash)
        Write-Host ('REMOTE_OVERRIDE_FIX=' + $remoteOverrideFixMode)
        exit 0
    }
    if ($posReplace -lt 0 -and $remoteOverrideFixMode -ne 'ALREADY_FIXED') {
        Write-LegacyPatchResidueHint
        throw '特征校验失败：未找到已补丁 other 槽位与 remote override 修补，拒绝反修补。'
    }
    if ($posSearch -ge 0 -and $posReplace -ge 0) {
        Write-LegacyPatchResidueHint
        throw '特征校验失败：检测到原始 doubao 与已补丁 other 特征同时存在，状态混杂，拒绝反修补。'
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $patchDir ('app.asar.' + $installTag + '.' + $timestamp + '.bak')
    $unpatchedCopy = Join-Path $patchDir ('app.asar.' + $installTag + '.' + $timestamp + '.unpatched')
    $unpatchTargetOffset = if ($posReplace -ge 0) { $posReplace } elseif ($posRemoteReplace -ge 0) { $posRemoteReplace } else { -1 }

    Write-Step ('命中偏移 replace=' + $posReplace + ' remoteReplace=' + $posRemoteReplace + ' guard=' + $posGuard)
    Write-Step ('备份将保存到 ' + $backup)
    Write-Step ('unpatched 副本将保存到 ' + $unpatchedCopy)

    [byte[]]$unpatchedCandidate = $bytes
    if ($posReplace -ge 0) {
        $unpatchedCandidate = New-ReplacedBytes $unpatchedCandidate $posReplace $search
    }
    if ($posRemoteReplace -ge 0) {
        $unpatchedCandidate = New-ReplacedBytes $unpatchedCandidate $posRemoteReplace $remoteOverrideSearch
    }
    $unpatchedBuild = Update-AsarIntegrityForModifiedOffset $unpatchedCandidate $unpatchTargetOffset
    [byte[]]$unpatched = $unpatchedBuild.Bytes

    Write-Step ('目标文件=' + $unpatchedBuild.TargetPath)
    Write-Step ('目标文件 SHA256=' + $unpatchedBuild.TargetFileHash)
    Write-Step ('ASAR 头部 SHA256=' + $unpatchedBuild.HeaderHash)

    [System.IO.File]::WriteAllBytes($unpatchedCopy, $unpatched)

    $verifyUnpatched = [System.IO.File]::ReadAllBytes($unpatchedCopy)
    $verifySearchPos = Find-Bytes $verifyUnpatched $search 0
    $verifyReplacePos = Find-Bytes $verifyUnpatched $replace 0
    $verifyRemoteSearchPos = Find-Bytes $verifyUnpatched $remoteOverrideSearch 0
    $verifyRemoteReplacePos = Find-Bytes $verifyUnpatched $remoteOverrideReplace 0
    if ($posReplace -ge 0 -and ($verifySearchPos -lt 0 -or $verifyReplacePos -ge 0)) {
        throw 'unpatched 副本校验失败：未恢复到原始 doubao 特征。'
    }
    if ($posRemoteReplace -ge 0 -and ($verifyRemoteSearchPos -lt 0 -or $verifyRemoteReplacePos -ge 0)) {
        throw 'unpatched 副本校验失败：未恢复 modelApi 远端覆盖原始特征。'
    }
    $verifyUnpatchedIntegrity = Get-AsarIntegrityStateForOffset $verifyUnpatched $unpatchTargetOffset
    if (-not $verifyUnpatchedIntegrity.IntegrityMatch) {
        throw 'unpatched 副本校验失败：目标文件的 ASAR 完整性记录未同步。'
    }

    if ($DryRun) {
        Write-Host 'DRY_RUN_OK' -ForegroundColor Green
        Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
        Write-Host ('UNPATCHED_COPY=' + $unpatchedCopy)
        Write-Host ('WOULD_BACKUP_TO=' + $backup)
        Write-Host ('WOULD_UPDATE_EXE=' + $exePath)
        Write-Host ('WOULD_WRITE_HEADER_SHA256=' + $unpatchedBuild.HeaderHash)
        Write-Host ('TARGET_PATH=' + $unpatchedBuild.TargetPath)
        Write-Host ('REMOTE_OVERRIDE_FIX=' + $remoteOverrideFixMode)
        exit 0
    }

    Stop-QClawProcess
    Copy-Item -LiteralPath $asarPath -Destination $backup -Force
    $unpatchResult = Write-AsarAndSyncEmbeddedIntegrity $asarPath $exePath $unpatched $unpatchedBuild.HeaderHash $bytes $currentRawHeaderHash '反修补'

    Write-Host 'UNPATCH_OK' -ForegroundColor Green
    Write-Host ('TARGET=' + $asarPath)
    Write-Host ('EXE=' + $exePath)
    Write-Host ('BACKUP=' + $backup)
    Write-Host ('UNPATCHED_COPY=' + $unpatchedCopy)
    Write-Host ('SHA256=' + $unpatchResult.AsarHash)
    Write-Host ('ASAR_HEADER_SHA256=' + $unpatchResult.EmbeddedHeaderHash)
    Write-Host ('REMOTE_OVERRIDE_FIX=' + $remoteOverrideFixMode)
    exit 0
}

if ($posGuard -lt 0) {
    Write-LegacyPatchResidueHint
    throw '特征校验失败：未找到兼容的 other 分支逻辑，拒绝补丁。'
}
if ($posReplace2 -ge 0) {
    Write-LegacyPatchResidueHint
    throw "安全校验失败：已补丁定位串出现多次 [$posReplace, $posReplace2]，拒绝补丁。"
}
if ($posSearch2 -ge 0) {
    Write-LegacyPatchResidueHint
    throw "安全校验失败：原始定位串出现多次 [$posSearch, $posSearch2]，拒绝补丁。"
}
if ($remoteOverrideFixMode -eq 'AMBIGUOUS') {
    Write-LegacyPatchResidueHint
    throw '安全校验失败：modelApi 远端覆盖特征出现多次，拒绝补丁。'
}
if ($remoteOverrideFixMode -eq 'MIXED') {
    Write-LegacyPatchResidueHint
    throw '安全校验失败：modelApi 远端覆盖特征状态混杂，拒绝补丁。'
}
$patchMode = 'PATCH'
$targetOffset = $posSearch

if ($posReplace -ge 0 -and $posSearch -lt 0) {
    $patchedIntegrityState = Get-AsarIntegrityStateForOffset $bytes $posReplace
    if ($patchedIntegrityState.IntegrityMatch -and $currentEmbeddedHeaderHash -ceq $currentRawHeaderHash) {
        $pendingFixModes = @()
        if ($remoteOverrideFixMode -eq 'PATCH') {
            $pendingFixModes += 'REMOTE_OVERRIDE'
        }
        if ($skillHubFixMode -eq 'PATCH') {
            $pendingFixModes += 'SKILLHUB'
        }
        if ($sharpFixMode -eq 'PATCH') {
            $pendingFixModes += 'SHARP'
        }
        if ($pendingFixModes.Count -gt 0) {
            $patchMode = (($pendingFixModes -join '_AND_') + '_FIX_ONLY')
            if ($remoteOverrideFixMode -eq 'PATCH') {
                $targetOffset = $posRemoteSearch
            } else {
                $targetOffset = $posReplace
            }
        } else {
            Write-Host 'ALREADY_PATCHED' -ForegroundColor Yellow
            Write-Host ('APP_ASAR=' + $asarPath)
            Write-Host ('EXE=' + $exePath)
            Write-Host ('PATCH_OFFSET=' + $posReplace)
            Write-Host ('TARGET_PATH=' + $patchedIntegrityState.Path)
            Write-Host ('ASAR_HEADER_SHA256=' + $currentRawHeaderHash)
            Write-Host ('REMOTE_OVERRIDE_FIX=' + $remoteOverrideFixMode)
            Write-Host ('SKILLHUB_REGEX_FIX=' + $skillHubFixMode)
            Write-Host ('SHARP_FIX=' + $sharpFixMode)
            Write-SharpStateSummary $sharpFixState
            exit 0
        }
    } else {
        $patchMode = 'REPAIR_PATCHED'
        if ($remoteOverrideFixMode -eq 'PATCH') {
            $targetOffset = $posRemoteSearch
        } else {
            $targetOffset = $posReplace
        }
    }
}

if ($patchMode -eq 'PATCH') {
    if ($posSearch -lt 0) {
        Write-LegacyPatchResidueHint
        throw '特征校验失败：未找到原始 doubao 槽位，拒绝补丁。'
    }
    if ($posReplace -ge 0) {
        Write-LegacyPatchResidueHint
        throw '特征校验失败：检测到原始 doubao 与已补丁 other 特征同时存在，状态混杂，拒绝补丁。'
    }

    $searchIntegrityState = Get-AsarIntegrityStateForOffset $bytes $posSearch
    if (-not $searchIntegrityState.IntegrityMatch) {
        Write-LegacyPatchResidueHint
        throw '补丁前校验失败：原始目标文件的 ASAR 完整性记录不一致，拒绝补丁。'
    }
}

$skillHubFixBackup = $null
$skillHubFixFixedCopy = $null
$skillHubFixedContent = $null
if ($skillHubFixMode -eq 'PATCH') {
    $skillHubFixTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $skillHubFixBackup = Join-Path $patchDir ('skillhub-installer.ts.' + $installTag + '.' + $skillHubFixTimestamp + '.bak')
    $skillHubFixFixedCopy = Join-Path $patchDir ('skillhub-installer.ts.' + $installTag + '.' + $skillHubFixTimestamp + '.fixed')
    $skillHubFixedContent = New-SkillHubRegexFixedContent $skillHubFixState
    [System.IO.File]::WriteAllText($skillHubFixFixedCopy, $skillHubFixedContent, [System.Text.UTF8Encoding]::new($false))
    $verifySkillHubFixed = [System.IO.File]::ReadAllText($skillHubFixFixedCopy)
    if ((Get-TextHitCount $verifySkillHubFixed $skillHubRegexFixLegacyRuntimePattern) -gt 0 -or
        (Get-TextHitCount $verifySkillHubFixed $skillHubRegexFixLegacySchemaPattern) -gt 0 -or
        (Get-TextHitCount $verifySkillHubFixed $skillHubRegexFixTransitionalSchemaPattern) -gt 0 -or
        (Get-TextHitCount $verifySkillHubFixed $skillHubRegexFixPatchedRuntimePattern) -ne 1 -or
        (Get-TextHitCount $verifySkillHubFixed $skillHubRegexFixPatchedSchemaPattern) -ne 1) {
        throw 'skillhub fixed 副本校验失败：未写入唯一兼容特征。'
    }
}

if ($patchMode -like '*FIX_ONLY' -and $patchMode -notlike '*REMOTE_OVERRIDE*') {
    $fixOnlyLabels = @()
    if ($patchMode -like '*SKILLHUB*') {
        $fixOnlyLabels += 'skillhub-installer regex'
    }
    if ($patchMode -like '*SHARP*') {
        $fixOnlyLabels += 'sharp 依赖'
    }
    Write-Step ('检测到 app.asar 已补丁，将单独修复 ' + (($fixOnlyLabels | Where-Object { $_ }) -join ' 与 '))
    if ($skillHubFixMode -eq 'PATCH') {
        Write-Step ('skillhub 备份将保存到 ' + $skillHubFixBackup)
        Write-Step ('skillhub fixed 副本将保存到 ' + $skillHubFixFixedCopy)
    }
    if ($sharpFixMode -eq 'PATCH') {
        Write-Step ('sharp 将修复到 ' + $sharpFixState.TargetVersion + ' @ ' + $sharpFixState.OpenClawRoot)
    }

    if ($DryRun) {
        Write-Host 'DRY_RUN_OK' -ForegroundColor Green
        Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
        if ($skillHubFixMode -eq 'PATCH') {
            Write-Host ('SKILLHUB_TARGET=' + $skillHubFixState.FilePath)
            Write-Host ('SKILLHUB_FIXED_COPY=' + $skillHubFixFixedCopy)
            Write-Host ('SKILLHUB_WOULD_BACKUP_TO=' + $skillHubFixBackup)
        }
        Write-Host ('REMOTE_OVERRIDE_FIX=' + $remoteOverrideFixMode)
        Write-Host ('SHARP_FIX=' + $sharpFixMode)
        Write-SharpStateSummary $sharpFixState
        Write-Host ('MODE=' + $patchMode)
        exit 0
    }

    Stop-QClawProcess
    if ($skillHubFixMode -eq 'PATCH') {
        Copy-Item -LiteralPath $skillHubFixState.FilePath -Destination $skillHubFixBackup -Force
        [System.IO.File]::WriteAllText($skillHubFixState.FilePath, $skillHubFixedContent, [System.Text.UTF8Encoding]::new($false))
        $verifySkillHubWrite = [System.IO.File]::ReadAllText($skillHubFixState.FilePath)
        if ((Get-TextHitCount $verifySkillHubWrite $skillHubRegexFixLegacyRuntimePattern) -gt 0 -or
            (Get-TextHitCount $verifySkillHubWrite $skillHubRegexFixLegacySchemaPattern) -gt 0 -or
            (Get-TextHitCount $verifySkillHubWrite $skillHubRegexFixTransitionalSchemaPattern) -gt 0 -or
            (Get-TextHitCount $verifySkillHubWrite $skillHubRegexFixPatchedRuntimePattern) -ne 1 -or
            (Get-TextHitCount $verifySkillHubWrite $skillHubRegexFixPatchedSchemaPattern) -ne 1) {
            throw 'skillhub-installer regex 修补写回校验失败。'
        }
    }
    if ($sharpFixMode -eq 'PATCH') {
        $sharpFixState = Invoke-SharpRepair $sharpFixState
        $sharpFixMode = 'ALREADY_OK'
    }

    Write-Host 'PATCH_OK' -ForegroundColor Green
    if ($skillHubFixMode -eq 'PATCH') {
        Write-Host ('SKILLHUB_TARGET=' + $skillHubFixState.FilePath)
        Write-Host ('SKILLHUB_BACKUP=' + $skillHubFixBackup)
        Write-Host ('SKILLHUB_FIXED_COPY=' + $skillHubFixFixedCopy)
    }
    Write-Host ('REMOTE_OVERRIDE_FIX=' + $remoteOverrideFixMode)
    Write-Host ('SHARP_FIX=' + $sharpFixMode)
    Write-SharpStateSummary $sharpFixState
    Write-Host ('MODE=' + $patchMode)
    exit 0
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $patchDir ('app.asar.' + $installTag + '.' + $timestamp + '.bak')
$patchedCopy = Join-Path $patchDir ('app.asar.' + $installTag + '.' + $timestamp + '.patched')

if ($patchMode -eq 'REPAIR_PATCHED') {
    Write-Step ('检测到已补丁但完整性未同步，将执行修复写回 replace=' + $posReplace + ' guard=' + $posGuard)
} elseif ($patchMode -like '*REMOTE_OVERRIDE*') {
    Write-Step ('检测到 app.asar 已完成 provider 替换，但仍存在 modelApi 远端覆盖，将执行二阶段修补 remoteSearch=' + $posRemoteSearch + ' guard=' + $posGuard)
} else {
    Write-Step ('命中偏移 search=' + $posSearch + ' guard=' + $posGuard)
}
Write-Step ('备份将保存到 ' + $backup)
Write-Step ('patched 副本将保存到 ' + $patchedCopy)

[byte[]]$patchedCandidate = $bytes
if ($patchMode -eq 'PATCH') {
    $patchedCandidate = New-ReplacedBytes $patchedCandidate $posSearch $replace
}
if ($remoteOverrideFixMode -eq 'PATCH') {
    $patchedCandidate = New-ReplacedBytes $patchedCandidate $posRemoteSearch $remoteOverrideReplace
}
$patchedBuild = Update-AsarIntegrityForModifiedOffset $patchedCandidate $targetOffset

[byte[]]$patched = $patchedBuild.Bytes
Write-Step ('目标文件=' + $patchedBuild.TargetPath)
Write-Step ('目标文件 SHA256=' + $patchedBuild.TargetFileHash)
Write-Step ('ASAR 头部 SHA256=' + $patchedBuild.HeaderHash)

[System.IO.File]::WriteAllBytes($patchedCopy, $patched)

$verifyPatched = [System.IO.File]::ReadAllBytes($patchedCopy)
$verifyPos = Find-Bytes $verifyPatched $replace 0
$verifySearchPos = Find-Bytes $verifyPatched $search 0
$verifyRemoteSearchPos = Find-Bytes $verifyPatched $remoteOverrideSearch 0
$verifyRemoteReplacePos = Find-Bytes $verifyPatched $remoteOverrideReplace 0
if ($verifyPos -lt 0 -or $verifySearchPos -ge 0) {
    throw 'patched 副本校验失败：未写入唯一目标特征。'
}
if ($remoteOverrideFixMode -eq 'PATCH' -and ($verifyRemoteReplacePos -lt 0 -or $verifyRemoteSearchPos -ge 0)) {
    throw 'patched 副本校验失败：未禁用 modelApi 远端覆盖。'
}
$verifyPatchedIntegrity = Get-AsarIntegrityStateForOffset $verifyPatched $targetOffset
if (-not $verifyPatchedIntegrity.IntegrityMatch) {
    throw 'patched 副本校验失败：目标文件的 ASAR 完整性记录未同步。'
}

if ($DryRun) {
    Write-Host 'DRY_RUN_OK' -ForegroundColor Green
    Write-Host ('INSTALL_ROOT=' + $resolvedRoot)
    Write-Host ('PATCHED_COPY=' + $patchedCopy)
    Write-Host ('WOULD_BACKUP_TO=' + $backup)
    Write-Host ('WOULD_UPDATE_EXE=' + $exePath)
    Write-Host ('WOULD_WRITE_HEADER_SHA256=' + $patchedBuild.HeaderHash)
    Write-Host ('TARGET_PATH=' + $patchedBuild.TargetPath)
    if ($skillHubFixMode -eq 'PATCH') {
        Write-Host ('SKILLHUB_TARGET=' + $skillHubFixState.FilePath)
        Write-Host ('SKILLHUB_FIXED_COPY=' + $skillHubFixFixedCopy)
        Write-Host ('SKILLHUB_WOULD_BACKUP_TO=' + $skillHubFixBackup)
    }
    Write-Host ('REMOTE_OVERRIDE_FIX=' + $remoteOverrideFixMode)
    Write-Host ('SKILLHUB_REGEX_FIX=' + $skillHubFixMode)
    Write-Host ('SHARP_FIX=' + $sharpFixMode)
    Write-SharpStateSummary $sharpFixState
    Write-Host ('MODE=' + $patchMode)
    exit 0
}

Stop-QClawProcess
if ($skillHubFixMode -eq 'PATCH') {
    Copy-Item -LiteralPath $skillHubFixState.FilePath -Destination $skillHubFixBackup -Force
    [System.IO.File]::WriteAllText($skillHubFixState.FilePath, $skillHubFixedContent, [System.Text.UTF8Encoding]::new($false))
    $verifySkillHubWrite = [System.IO.File]::ReadAllText($skillHubFixState.FilePath)
    if ((Get-TextHitCount $verifySkillHubWrite $skillHubRegexFixLegacyRuntimePattern) -gt 0 -or
        (Get-TextHitCount $verifySkillHubWrite $skillHubRegexFixLegacySchemaPattern) -gt 0 -or
        (Get-TextHitCount $verifySkillHubWrite $skillHubRegexFixTransitionalSchemaPattern) -gt 0 -or
        (Get-TextHitCount $verifySkillHubWrite $skillHubRegexFixPatchedRuntimePattern) -ne 1 -or
        (Get-TextHitCount $verifySkillHubWrite $skillHubRegexFixPatchedSchemaPattern) -ne 1) {
        throw 'skillhub-installer regex 修补写回校验失败。'
    }
}
if ($sharpFixMode -eq 'PATCH') {
    $sharpFixState = Invoke-SharpRepair $sharpFixState
    $sharpFixMode = 'ALREADY_OK'
}
Copy-Item -LiteralPath $asarPath -Destination $backup -Force
$patchResult = Write-AsarAndSyncEmbeddedIntegrity $asarPath $exePath $patched $patchedBuild.HeaderHash $bytes $currentRawHeaderHash '补丁'

Write-Host 'PATCH_OK' -ForegroundColor Green
Write-Host ('TARGET=' + $asarPath)
Write-Host ('EXE=' + $exePath)
Write-Host ('BACKUP=' + $backup)
Write-Host ('PATCHED_COPY=' + $patchedCopy)
Write-Host ('SHA256=' + $patchResult.AsarHash)
Write-Host ('ASAR_HEADER_SHA256=' + $patchResult.EmbeddedHeaderHash)
if ($skillHubFixMode -eq 'PATCH') {
    Write-Host ('SKILLHUB_TARGET=' + $skillHubFixState.FilePath)
    Write-Host ('SKILLHUB_BACKUP=' + $skillHubFixBackup)
    Write-Host ('SKILLHUB_FIXED_COPY=' + $skillHubFixFixedCopy)
}
Write-Host ('REMOTE_OVERRIDE_FIX=' + $remoteOverrideFixMode)
Write-Host ('SKILLHUB_REGEX_FIX=' + $skillHubFixMode)
Write-Host ('SHARP_FIX=' + $sharpFixMode)
Write-SharpStateSummary $sharpFixState
Write-Host ('MODE=' + $patchMode)
