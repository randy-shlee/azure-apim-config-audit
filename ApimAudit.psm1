#requires -Version 7.2
function Invoke-ApimConfigAudit {
    [CmdletBinding(DefaultParameterSetName = 'Csv')]
    param(
        [Parameter(Mandatory)][string]$ApimResourceId,
        [Parameter(Mandatory, ParameterSetName = 'Csv')][string]$OutputPath,
        [Parameter(Mandatory, ParameterSetName = 'Rows')][switch]$PassThru,
        [string]$FoundryResourceId,
        [switch]$CompareFoundryKeys,
        [switch]$CompareLabFixture,
        [ValidateSet('Azure', 'Fixture')][string]$Source = 'Azure',
        [scriptblock]$FixtureRequest
    )

    $ErrorActionPreference = 'Stop'
    $idPattern = '^/subscriptions/(?<sub>[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})/resourceGroups/(?<rg>[\p{L}\p{N}_.()-]+)/providers/'
    if ($ApimResourceId -notmatch ($idPattern + 'Microsoft\.ApiManagement/service/(?<apim>[a-z0-9-]+)$')) {
        throw 'Pass a complete APIM service resource ID.'
    }
    $subscription = $Matches.sub
    $resourceGroupName = $Matches.rg
    $apimName = $Matches.apim
    if ($CompareLabFixture -and ($CompareFoundryKeys -or $FoundryResourceId)) {
        throw 'Mock comparison cannot be combined with a Foundry account or live-key comparison.'
    }
    if ($CompareFoundryKeys -and (
            $FoundryResourceId -notmatch ($idPattern + 'Microsoft\.CognitiveServices/accounts/[a-z0-9_.-]+$') -or
            $Matches.sub -ne $subscription)) {
        throw 'Key comparison requires an explicit Foundry account ID in the same subscription.'
    }

    if ($Source -eq 'Fixture') {
        if (-not $FixtureRequest) { throw 'Fixture mode requires a fixture request handler.' }
    } else {
        if ($FixtureRequest) { throw 'Fixture request handlers cannot be used in Azure mode.' }
        $accessToken = az account get-access-token --subscription $subscription --resource 'https://management.azure.com/' --query accessToken -o tsv --only-show-errors 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $accessToken) { throw 'Could not authenticate to Azure Resource Manager. Check az login and the subscription.' }
        $token = ConvertTo-SecureString $accessToken -AsPlainText -Force
        $accessToken = $null
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $references = [System.Collections.Generic.List[object]]::new()
    $time = [DateTime]::UtcNow.ToString('o')
    $version = '2024-05-01'
    $statusLabelsKo = @{
        Unknown = '확인 불가'
        Partial = '부분 확인'
        Review = '검토 필요'
        Discovered = '발견됨'
        Inspected = '점검 완료'
        Complete = '조회 완료'
        NoneFound = '발견되지 않음'
        Match = '일치'
        NoMatch = '불일치'
        NotRequested = '비교 미요청'
        NotApplicable = '해당 없음'
        Referenced = '참조 방식'
        Inventory = '목록 확인'
        StaticReference = '설정상 참조 있음'
        NoStaticReference = '설정상 참조 미발견'
        StaticOnly = '정적 점검만 수행'
        DeveloperClassic = '클래식 개발자 계층'
        Classic = '클래식 계층'
        V2 = 'v2 계층'
        OtherSku = '기타 계층'
        NoVnetIntegration = 'VNet 미통합'
        SubnetConfigured = '서브넷 설정됨'
        Enabled = '사용'
        Disabled = '사용 안 함'
    }
    $storageLabelsKo = @{
        KeyVaultReference = 'Key Vault 참조'
        DirectSecret = '비밀 값 직접 저장'
        DirectPlainText = '평문 직접 저장'
        PolicyLiteral = '정책에 직접 입력된 값'
        Unknown = '저장 방식 확인 불가'
    }

    function Protect-Cell([string]$Text) {
        if ($Text -match '^\s*[=+@-]|^[\t\r\n]') { return "'$Text" }
        return $Text
    }

    function Add-Result($Check, [string]$Target, $Status, $Detail, [string]$DetailKo, $Storage = '', $ReferenceType = '', $ReferencedBy = '') {
        if ([string]::IsNullOrWhiteSpace($DetailKo)) { throw "Missing Korean audit detail for $Check." }
        if (-not $statusLabelsKo.ContainsKey($Status)) { throw "Missing Korean status label for $Check ($Status)." }
        $storageKo = ''
        if ($Storage) {
            if (-not $storageLabelsKo.ContainsKey($Storage)) { throw "Missing Korean storage label for $Check ($Storage)." }
            $storageKo = $storageLabelsKo[$Storage]
        }
        $resourceName = $Target
        if ($Target -eq $ApimResourceId -or $Target -eq '/policies/policy') {
            $resourceName = $apimName
        } elseif ($Target.StartsWith('/')) {
            $resourcePath = $Target -replace '/policies/policy$', ''
            $resourceName = [uri]::UnescapeDataString(($resourcePath -split '/')[-1])
        }
        $scopePath = if ($Check -eq 'NamedValueReference' -and $ReferencedBy) { $ReferencedBy } else { $Target }
        $scopeMatch = [regex]::Match($scopePath,
            '^(?:/workspaces/(?<workspace>[^/]+))?(?:/apis/(?<api>[^/;]+)(?:;rev=(?<revision>[^/]+))?(?:/operations/(?<operation>[^/]+))?)?(?=/|$)')
        $results.Add([pscustomobject][ordered]@{
            ResourceGroupName = Protect-Cell $resourceGroupName
            ApimName = Protect-Cell $apimName
            ApiName = Protect-Cell ([uri]::UnescapeDataString($scopeMatch.Groups['api'].Value))
            Check = $Check
            Status = $Status
            Storage = $Storage
            StatusKo = $statusLabelsKo[$Status]
            StorageKo = $storageKo
            WorkspaceName = Protect-Cell ([uri]::UnescapeDataString($scopeMatch.Groups['workspace'].Value))
            ApiRevision = Protect-Cell ([uri]::UnescapeDataString($scopeMatch.Groups['revision'].Value))
            OperationName = Protect-Cell ([uri]::UnescapeDataString($scopeMatch.Groups['operation'].Value))
            ResourceName = Protect-Cell $resourceName
            ReferenceType = $ReferenceType
            DetailKo = $DetailKo
            Detail = $Detail
            Target = Protect-Cell $Target
            ReferencedBy = Protect-Cell $ReferencedBy
            Source = $Source
            CheckedAtUtc = $time
            ApimResourceId = $ApimResourceId
        })
    }

    function Read-Arm([uri]$Uri, [string]$Method = 'GET') {
        if ($Uri.Scheme -ne 'https' -or $Uri.Host -ne 'management.azure.com' -or
            -not $Uri.IsDefaultPort -or $Uri.UserInfo -or
            -not $Uri.AbsolutePath.StartsWith("/subscriptions/$subscription/", [StringComparison]::OrdinalIgnoreCase)) {
            return @{ Status = 'UnexpectedArmUrl' }
        }
        if ($Source -eq 'Fixture') { return & $FixtureRequest $Uri $Method }
        try {
            $response = Invoke-WebRequest -Uri $Uri -Method $Method -Authentication Bearer -Token $token `
                -MaximumRedirection 0 -SkipHttpErrorCheck -TimeoutSec 60 -Verbose:$false -Debug:$false
        } catch {
            return @{ Status = 'RequestFailed' }
        }
        if ([int]$response.StatusCode -ne 200) { return @{ Status = [string]$response.StatusCode } }
        try {
            return @{ Status = '200'; Data = $response.Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
        } catch {
            return @{ Status = 'InvalidJson' }
        }
    }

    function Read-Apim([string]$Path, [string]$Query = '', [string]$Method = 'GET') {
        Read-Arm "https://management.azure.com${ApimResourceId}${Path}?api-version=${version}${Query}" $Method
    }

    function Read-Collection([string]$Path, [string]$Check = 'InventoryCoverage') {
        $url = "https://management.azure.com${ApimResourceId}${Path}?api-version=$version"
        $visited = [System.Collections.Generic.HashSet[string]]::new()
        $expectedPath = ([uri]$url).AbsolutePath
        while ($url) {
            $nextUri = $null
            if (-not [uri]::TryCreate($url, [UriKind]::Absolute, [ref]$nextUri) -or
                $nextUri.AbsolutePath -cne $expectedPath -or -not $visited.Add($url)) {
                Add-Result $Check $Path 'Unknown' 'Invalid or repeated collection pagination link.' `
                    '목록의 다음 페이지 링크가 잘못되었거나 반복되었습니다.'
                break
            }
            $page = Read-Arm $nextUri
            if ($page.Status -ne '200' -or $page.Data.value -isnot [array]) {
                Add-Result $Check $Path 'Unknown' "Collection unavailable or invalid ($($page.Status))." `
                    "목록을 조회할 수 없거나 응답 형식이 올바르지 않습니다 ($($page.Status))."
                break
            }
            $page.Data.value
            $url = $page.Data.nextLink
        }
    }

    function Add-References([string]$Text, [string]$Type, [string]$Path) {
        foreach ($match in [regex]::Matches($Text, '\{\{\s*([^{}\r\n]+?)\s*\}\}')) {
            $references.Add(@{ Name = $match.Groups[1].Value; Type = $Type; Path = $Path })
        }
    }

    function Find-InlinePolicyCredential([System.Xml.Linq.XDocument]$Xml, [string]$Path, [string]$Type) {
        $credentialHeaders = @('api-key', 'x-api-key', 'apikey', 'ocp-apim-subscription-key', 'subscription-key', 'ocp-apim-subscription-token')
        $credentialParameters = @('api-key', 'api_key', 'apikey', 'subscription-key', 'access_token', 'client_secret')
        foreach ($element in $Xml.Descendants()) {
            $directive = $element.Name.LocalName
            $name = ([string]$element.Attribute('name').Value).ToLowerInvariant()
            $field = $null
            $values = @()
            switch -CaseSensitive ($directive) {
                'set-header' {
                    if ($name -in $credentialHeaders -or $name -eq 'authorization') {
                        $field = $name
                        $values = @($element.Elements() | Where-Object { $_.Name.LocalName -ceq 'value' })
                    }
                }
                'set-query-parameter' {
                    if ($name -in $credentialParameters) {
                        $field = $name
                        $values = @($element.Elements() | Where-Object { $_.Name.LocalName -ceq 'value' })
                    }
                }
                'authentication-basic' {
                    $field = 'password'
                    if ($null -ne $element.Attribute('password')) {
                        $values = @($element.Attribute('password'))
                    }
                }
            }
            foreach ($valueNode in $values) {
                $value = $valueNode.Value.Trim()
                if (-not $value -or $value -match '\{\{[^{}]+\}\}|@\s*[\(\{]') { continue }
                if ($field -eq 'authorization' -and $value -notmatch '^(Bearer|Basic)\s+\S+$') { continue }
                $line = ([System.Xml.IXmlLineInfo]$valueNode).LineNumber
                Add-Result 'PolicyInlineCredential' $Path 'Review' `
                    "Possible hardcoded credential in $directive / $field (policy XML line $line). Value omitted; validity not checked." `
                    "정책 XML ${line}행의 $directive / $field 필드에 자격 증명이 직접 입력된 것으로 의심됩니다. 값은 표시하지 않으며 유효성은 확인하지 않았습니다." `
                    'PolicyLiteral' $Type
            }
        }
    }

    function Get-PolicySecretShape([string]$Literal) {
        $shapes = @(
            @{ Type = 'AzureStorageAccountKey'; Pattern = '(?i)\bAccountKey[ \t]*=[ \t]*[a-z0-9+/]{40,}={0,2}(?![a-z0-9+/=])' },
            @{ Type = 'JwtLike'; Pattern = '(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{5,}\.eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{8,}(?![A-Za-z0-9_-])' },
            @{ Type = 'ProviderTokenPrefix'; Pattern = '(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|sk_(?:live|test)_[A-Za-z0-9]{20,})(?![A-Za-z0-9_])' },
            @{ Type = 'PrivateKeyMarker'; Pattern = '-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----' }
        )
        $matched = $false
        foreach ($shape in $shapes) {
            if ($Literal -cmatch $shape.Pattern) {
                $shape.Type
                $matched = $true
            }
        }
        if ($matched) { return }

        foreach ($match in [regex]::Matches($Literal, '(?<![A-Za-z0-9_+/-])[A-Za-z0-9_+/-]{24,128}(?![A-Za-z0-9_+/-])')) {
            $candidate = $match.Value
            if ($candidate -match '^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$' -or
                $candidate -notmatch '[a-z]' -or $candidate -notmatch '[0-9]') { continue }
            $threshold = if ($candidate -match '^[0-9a-f]{32,128}$') { 3.3 } else { 3.8 }
            $counts = [System.Collections.Generic.Dictionary[char,int]]::new()
            foreach ($character in $candidate.ToCharArray()) {
                if (-not $counts.ContainsKey($character)) { $counts[$character] = 0 }
                $counts[$character]++
            }
            $entropy = 0.0
            foreach ($count in $counts.Values) {
                $probability = $count / $candidate.Length
                $entropy -= $probability * [Math]::Log2($probability)
            }
            if ($entropy -ge $threshold) { return 'HighEntropyToken' }
        }
    }

    function Get-PolicyValueNode([System.Xml.Linq.XDocument]$Xml) {
        foreach ($element in $Xml.Descendants()) {
            $element.Attributes() | Where-Object { -not $_.IsNamespaceDeclaration -and $_.Name.LocalName -cnotin @('name', 'id') }
            $element.Nodes() | Where-Object { $_ -is [System.Xml.Linq.XText] }
        }
    }

    function Compare-PolicyFoundryKey([System.Xml.Linq.XDocument]$Xml, [string]$Path, [string]$Type) {
        $foundMatch = $false
        foreach ($node in (Get-PolicyValueNode $Xml)) {
            $candidate = $node.Value.Trim()
            if (-not $candidate -or $candidate -match '\{\{[^{}]+\}\}|@\s*[\(\{]') { continue }
            if ($candidate -match '^Bearer[ \t]+(?<token>\S+)$') { $candidate = $Matches.token }
            if (-not ([string]::Equals($candidate, $currentKeys[0], [StringComparison]::Ordinal) -or
                      [string]::Equals($candidate, $currentKeys[1], [StringComparison]::Ordinal))) { continue }
            $foundMatch = $true
            $line = ([System.Xml.IXmlLineInfo]$node).LineNumber
            Add-Result 'PolicyFoundryKeyMatch' $Path 'Match' `
                "A policy literal matches a current key of the selected Foundry account (policy XML line $line). Key omitted." `
                "정책 XML ${line}행의 값이 지정한 Foundry 계정의 현재 키와 일치합니다. 키 원문은 표시하지 않습니다." `
                'PolicyLiteral' $Type
        }
        if (-not $foundMatch) {
            Add-Result 'PolicyFoundryKeyMatch' $Path 'NoMatch' `
                'No exact match in checked policy literals against the selected account current keys.' `
                '검사한 정책 값 중 지정한 Foundry 계정의 현재 키와 일치하는 값이 없습니다.' `
                'PolicyLiteral' $Type
        }
    }

    function Find-PolicySecretShape([System.Xml.Linq.XDocument]$Xml, [string]$Path, [string]$Type) {
        foreach ($node in (Get-PolicyValueNode $Xml)) {
            $literal = $node.Value
            if ([string]::IsNullOrWhiteSpace($literal) -or $literal -match '@\s*[\(\{]') { continue }
            $literal = [regex]::Replace($literal, '\{\{[^{}]+\}\}', ' ')
            foreach ($shape in (Get-PolicySecretShape $literal)) {
            $line = ([System.Xml.IXmlLineInfo]$node).LineNumber
            $location = if ($node -is [System.Xml.Linq.XAttribute]) { 'XML attribute' } else { 'XML text' }
            $reason = if ($shape -ceq 'HighEntropyToken') {
                'High-entropy string; may be a hash or identifier.'
            } else {
                'Recognizable credential format.'
            }
            $locationKo = if ($node -is [System.Xml.Linq.XAttribute]) { 'XML 속성' } else { 'XML 텍스트' }
            $shapeKo = switch ($shape) {
                'AzureStorageAccountKey' { 'Azure Storage 계정 키 후보' }
                'JwtLike' { 'JWT 형식 후보' }
                'ProviderTokenPrefix' { '서비스 공급자 토큰 접두사' }
                'PrivateKeyMarker' { '개인 키 시작 표식' }
                'HighEntropyToken' { '무작위성이 높은 문자열' }
            }
            $reasonKo = if ($shape -ceq 'HighEntropyToken') {
                '해시나 식별자일 수도 있습니다.'
            } else {
                '알려진 자격 증명 형식과 일치합니다.'
            }
            Add-Result 'PolicySecretShape' $Path 'Review' `
                "$shape in $location (policy XML line $line). $reason Value omitted; validity not checked." `
                "정책 XML ${line}행의 ${locationKo}: $shapeKo. $reasonKo 값은 표시하지 않으며 유효성은 확인하지 않았습니다." `
                'PolicyLiteral' $Type
            }
        }
    }

    function Read-Policy([string]$Path, [switch]$Fragment) {
        $policy = Read-Apim $Path '&format=xml'
        if ($policy.Status -eq '404' -and -not $Fragment) { return $true }
        if ($policy.Status -ne '200' -or [string]::IsNullOrWhiteSpace($policy.Data.properties.value) -or
            $policy.Data.properties.format -notin @('rawxml', 'xml')) {
            Add-Result 'ReferenceCoverage' $Path 'Unknown' "Inline policy unavailable ($($policy.Status))." `
                "정책 본문을 조회할 수 없습니다 ($($policy.Status))."
            return $false
        }
        $settings = [System.Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $settings.IgnoreComments = $true
        $settings.MaxCharactersInDocument = 10000000
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($policy.Data.properties.value), $settings)
        try {
            $xml = [System.Xml.Linq.XDocument]::Load($reader, [System.Xml.Linq.LoadOptions]::SetLineInfo)
            $policyType = if ($Fragment) { 'Fragment' } else { 'Policy' }
            Add-References $xml.ToString() $policyType $Path
            Find-InlinePolicyCredential $xml $Path $policyType
            Find-PolicySecretShape $xml $Path $policyType
            if ($CompareFoundryKeys -and $currentKeys) {
                Compare-PolicyFoundryKey $xml $Path $policyType
            }
            return $true
        } catch [System.Xml.XmlException] {
            Add-Result 'ReferenceCoverage' $Path 'Unknown' 'Policy is not parseable XML; contents not included.' `
                '정책을 XML로 읽을 수 없습니다. 정책 내용은 포함하지 않았습니다.'
            return $false
        } finally {
            $reader.Dispose()
        }
    }

    function Read-ReferenceScope([string]$Prefix) {
        $null = Read-Policy "$Prefix/policies/policy"
        foreach ($fragment in (Read-Collection "$Prefix/policyFragments" 'ReferenceCoverage')) {
            $null = Read-Policy "$Prefix/policyFragments/$([uri]::EscapeDataString($fragment.name))" -Fragment
        }
        foreach ($product in (Read-Collection "$Prefix/products" 'ReferenceCoverage')) {
            $null = Read-Policy "$Prefix/products/$([uri]::EscapeDataString($product.name))/policies/policy"
        }
        $apiGroups = Read-Collection "$Prefix/apis" 'ReferenceCoverage' |
            Group-Object { $_.name -replace ';rev=[^;]+$', '' }
        foreach ($apiGroup in $apiGroups) {
            $base = "$Prefix/apis/$([uri]::EscapeDataString($apiGroup.Name))"
            $revisionStart = $results.Count
            $revisions = @(Read-Collection "$base/revisions" 'ReferenceCoverage')
            $apiPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $null = $apiPaths.Add($base)
            $current = $revisions | Where-Object { $_.isCurrent -eq $true } | Select-Object -First 1
            foreach ($revision in $revisions) {
                if ($revision.isCurrent -eq $false -and $revision.apiRevision) {
                    $null = $apiPaths.Add("$base;rev=$([uri]::EscapeDataString($revision.apiRevision))")
                } elseif ($revision.isCurrent -isnot [bool] -or -not $revision.apiRevision) {
                    Add-Result 'ReferenceCoverage' "$base/revisions" 'Unknown' 'Revision entry is missing its ID or current flag.' `
                        '리비전 항목에 ID 또는 현재 리비전 여부가 누락되었습니다.'
                }
            }
            foreach ($api in $apiGroup.Group) {
                if ($api.name -match ';rev=(?<revision>[^;]+)$' -and
                    $Matches.revision -ne $current.apiRevision -and $api.properties.isCurrent -ne $true) {
                    $null = $apiPaths.Add("$base;rev=$([uri]::EscapeDataString($Matches.revision))")
                }
            }
            Add-Result 'ApiInventory' $base $(if ($results.Count -eq $revisionStart) { 'Discovered' } else { 'Partial' }) `
                "API found; current and historical paths to inspect: $($apiPaths.Count)." `
                "API를 찾았습니다. 점검 대상 경로(현재 및 이전 리비전): $($apiPaths.Count)개."

            foreach ($path in $apiPaths) {
                $revisionPartial = -not (Read-Policy "$path/policies/policy")
                $issueCount = $results.Count
                $operations = @(Read-Collection "$path/operations" 'ReferenceCoverage')
                $revisionPartial = $revisionPartial -or $results.Count -ne $issueCount
                foreach ($operation in $operations) {
                    $operationPath = "$path/operations/$([uri]::EscapeDataString($operation.name))"
                    $operationPartial = -not (Read-Policy "$operationPath/policies/policy")
                    $revisionPartial = $revisionPartial -or $operationPartial
                    Add-Result 'ApiOperationCoverage' $operationPath $(if ($operationPartial) { 'Partial' } else { 'Inspected' }) `
                        'Operation was discovered and its local policy was checked; no gateway request was sent.' `
                        '오퍼레이션과 해당 범위의 정책을 확인했습니다. 게이트웨이에는 요청을 보내지 않았습니다.'
                }
                Add-Result 'ApiRevisionCoverage' $path $(if ($revisionPartial) { 'Partial' } else { 'Inspected' }) `
                    "Operations returned: $($operations.Count). Local API and operation policies checked; runtime behavior not verified." `
                    "오퍼레이션 $($operations.Count)개를 조회했습니다. API 및 오퍼레이션 범위의 정책을 점검했으며, 실제 실행 동작은 검증하지 않았습니다."
            }
        }
        foreach ($backend in (Read-Collection "$Prefix/backends" 'ReferenceCoverage')) {
            $path = "$Prefix/backends/$([uri]::EscapeDataString($backend.name))"
            $item = Read-Apim $path
            if ($item.Status -ne '200' -or -not $item.Data.properties) {
                Add-Result 'ReferenceCoverage' $path 'Unknown' "Backend configuration unavailable ($($item.Status))." `
                    "Backend 설정을 조회할 수 없습니다 ($($item.Status))."
                continue
            }
            Add-References (ConvertTo-Json -InputObject $item.Data.properties -Depth 100 -Compress) 'Backend' $path
        }
    }

    function Read-NamedValueScope([string]$Prefix, [bool]$Partial) {
        $inventoryStart = $results.Count
        $namedValues = @(Read-Collection "$Prefix/namedValues" 'NamedValueInventory')
        if ($results.Count -eq $inventoryStart) {
            Add-Result 'NamedValueInventory' "$Prefix/namedValues" 'Complete' "Named Values returned: $($namedValues.Count)." `
                "Named Value $($namedValues.Count)개를 조회했습니다."
        }
        if (-not $Prefix -and $CompareLabFixture -and 'lab-marker' -cnotin $namedValues.name) {
            Add-Result 'FixtureKeyMatch' '/namedValues/lab-marker' 'Unknown' 'The tagged lab marker was not found or was not readable.' `
                '랩의 테스트용 값을 찾지 못했거나 조회할 수 없습니다.'
        }
        foreach ($nv in $namedValues) {
            $name = $nv.properties.displayName
            $path = "$Prefix/namedValues/$([uri]::EscapeDataString($nv.name))"
            if ($nv.properties.keyVault.secretIdentifier) {
                $storage = 'KeyVaultReference'
                $posture = 'Referenced'
            } elseif ($nv.properties.secret -eq $true) {
                $storage = 'DirectSecret'
                $posture = 'Review'
            } elseif ($nv.properties.secret -eq $false) {
                $storage = 'DirectPlainText'
                $posture = 'Inventory'
            } else {
                $storage = 'Unknown'
                $posture = 'Unknown'
            }
            Add-Result 'NamedValueStorage' $path $posture 'Storage classification from APIM metadata.' `
                'APIM 메타데이터를 기준으로 저장 방식을 분류했습니다.' $storage

            if (-not $Prefix -and $CompareLabFixture -and $nv.name -ceq 'lab-marker') {
                if ($storage -ne 'DirectSecret') {
                    Add-Result 'FixtureKeyMatch' $path 'Unknown' 'Expected a direct synthetic secret; no value was requested.' `
                        '직접 저장된 테스트용 비밀 값 형식이 아니어서 값 조회를 요청하지 않았습니다.' $storage
                } else {
                    $marker = Read-Apim "$path/listValue" '' 'POST'
                    if ($marker.Status -ne '200' -or $marker.Data.value -isnot [string]) {
                        Add-Result 'FixtureKeyMatch' $path 'Unknown' "Synthetic marker unavailable ($($marker.Status))." `
                            "테스트용 값을 조회할 수 없습니다 ($($marker.Status))." $storage
                    } else {
                        $status = if ($marker.Data.value -ceq 'synthetic-marker-not-a-credential') { 'Match' } else { 'NoMatch' }
                        Add-Result 'FixtureKeyMatch' $path $status 'Compared to the public synthetic marker; no Foundry resource queried.' `
                            '공개된 테스트용 값과 대조했습니다. Foundry 리소스는 조회하지 않았습니다.' $storage
                    }
                    $marker = $null
                }
            }

            if ($storage -in @('DirectSecret', 'DirectPlainText')) {
                if (-not $CompareFoundryKeys -or $Prefix) {
                    Add-Result 'FoundryKeyMatch' $path 'NotRequested' 'Explicit opt-in is required and applies only to service-level Named Values.' `
                        '명시적으로 옵션을 지정해야 하며, 서비스 범위의 Named Value에만 적용됩니다.' $storage
                } elseif ($keysDisabled) {
                    Add-Result 'FoundryKeyMatch' $path 'NotApplicable' $keysState $keysStateKo $storage
                } elseif (-not $currentKeys) {
                    Add-Result 'FoundryKeyMatch' $path 'Unknown' $keysState $keysStateKo $storage
                } else {
                    $secretResponse = Read-Apim "$path/listValue" '' 'POST'
                    if ($secretResponse.Status -ne '200' -or $secretResponse.Data.value -isnot [string]) {
                        Add-Result 'FoundryKeyMatch' $path 'Unknown' "Named Value unavailable ($($secretResponse.Status))." `
                            "Named Value의 값을 조회할 수 없습니다 ($($secretResponse.Status))." $storage
                    } else {
                        $matched = @($currentKeys | Where-Object { [string]::Equals($_, $secretResponse.Data.value, [StringComparison]::Ordinal) }).Count -gt 0
                        Add-Result 'FoundryKeyMatch' $path $(if ($matched) { 'Match' } else { 'NoMatch' }) `
                            'Exact comparison against the selected account current keys only.' `
                            '선택한 계정의 현재 키와만 정확히 일치하는지 비교했습니다.' $storage
                    }
                    $secretResponse = $null
                }
            }

            $hits = @($references | Where-Object { $name -and $_.Name -ceq $name } |
                Sort-Object -Property Type, Path -Unique)
            if ($hits.Count) {
                foreach ($hit in $hits) {
                    Add-Result 'NamedValueReference' $path 'StaticReference' 'Literal reference found; not proof of runtime usage.' `
                        '설정에 명시된 참조를 찾았습니다. 실제 실행 시 사용되었음을 뜻하지는 않습니다.' $storage $hit.Type $hit.Path
                }
            } else {
                $status = if ($Partial -or -not $name) { 'Unknown' } else { 'NoStaticReference' }
                Add-Result 'NamedValueReference' $path $status 'No visible literal reference; this does not prove the value is unused.' `
                    '조회 가능한 설정에서 명시된 참조를 찾지 못했습니다. 값이 사용되지 않는다는 뜻은 아닙니다.' $storage
            }
        }
    }

    $service = Read-Apim ''
    if ($CompareLabFixture -and ($service.Status -ne '200' -or $service.Data.sku.name -ne 'Developer' -or
            $service.Data.tags.purpose -cne 'apim-posture-lab' -or $service.Data.tags.labMode -cne 'mock-foundry')) {
        throw 'Mock comparison is restricted to the tagged Classic Developer mock lab.'
    }
    if ($service.Status -ne '200' -or -not $service.Data.sku.name) {
        Add-Result 'ServiceSku' $ApimResourceId 'Unknown' "APIM service unavailable or invalid ($($service.Status))." `
            "APIM 서비스를 조회할 수 없거나 응답이 올바르지 않습니다 ($($service.Status))."
    } else {
        $sku = $service.Data.sku.name
        $skuStatus = switch ($sku) {
            'Developer' { 'DeveloperClassic' }
            { $_ -in @('Basic', 'Standard', 'Premium') } { 'Classic' }
            { $_ -in @('BasicV2', 'StandardV2', 'PremiumV2') } { 'V2' }
            default { 'OtherSku' }
        }
        Add-Result 'ServiceSku' $ApimResourceId $skuStatus "ARM SKU: $sku. This is not a patch or advisory applicability check." `
            "ARM SKU: $sku. 패치 적용 여부나 보안 공지 대상 여부는 확인하지 않았습니다."
        $network = $service.Data.properties
        $vnetStatus = switch ($network.virtualNetworkType) {
            'None' { 'NoVnetIntegration' }
            { $_ -in @('Internal', 'External') } { if ($network.virtualNetworkConfiguration.subnetResourceId) { 'SubnetConfigured' } else { 'Unknown' } }
            default { 'Unknown' }
        }
        Add-Result 'VnetIntegration' $ApimResourceId $vnetStatus 'Primary-region ARM settings only; NSG rules, routes, DNS, and reachability are not verified.' `
            '기본 지역의 ARM 설정만 확인했습니다. NSG 규칙, 라우팅, DNS 및 연결 가능 여부는 검증하지 않았습니다.'
        $publicStatus = switch ($network.publicNetworkAccess) {
            'Enabled' { 'Enabled' }
            'Disabled' { 'Disabled' }
            default { 'Unknown' }
        }
        Add-Result 'PublicNetworkAccess' $ApimResourceId $publicStatus 'ARM property only; this does not prove which endpoints are reachable.' `
            'ARM 속성만 확인했습니다. 실제로 어떤 엔드포인트에 연결할 수 있는지는 검증하지 않았습니다.'
        $legacy = Read-Apim '/tenant/access'
        if ($legacy.Status -eq '200' -and $legacy.Data.properties.enabled -is [bool]) {
            Add-Result 'LegacyDirectManagementApi' '/tenant/access' $(if ($legacy.Data.properties.enabled) { 'Review' } else { 'Disabled' }) `
                'Direct management API setting reported by ARM.' 'ARM에서 조회한 직접 관리 API 설정입니다.'
        } else {
            Add-Result 'LegacyDirectManagementApi' '/tenant/access' 'Unknown' "Setting unavailable ($($legacy.Status))." `
                "설정을 조회할 수 없습니다 ($($legacy.Status))."
        }

        foreach ($surface in @(
                @{ Path = '/identityProviders'; Check = 'IdentityProviderInventory' },
                @{ Path = '/openidConnectProviders'; Check = 'OpenIdProviderInventory' },
                @{ Path = '/subscriptions'; Check = 'ApimSubscriptionInventory' }
            )) {
            $surfaceStart = $results.Count
            $items = @(Read-Collection $surface.Path $surface.Check)
            if ($results.Count -eq $surfaceStart) {
                Add-Result $surface.Check $surface.Path $(if ($items.Count) { 'Review' } else { 'NoneFound' }) `
                    "Configured objects: $($items.Count). No credential or rotation status verified." `
                    "설정된 항목: $($items.Count)개. 자격 증명이나 교체 여부는 확인하지 않았습니다."
            }
            $items = $null
        }

        $workspaceStart = $results.Count
        $workspaces = @(Read-Collection '/workspaces' 'WorkspaceInventory')
        $workspacePartial = $results.Count -ne $workspaceStart
        if (-not $workspacePartial) {
            Add-Result 'WorkspaceInventory' '/workspaces' 'Complete' "Workspaces returned: $($workspaces.Count)." `
                "워크스페이스 $($workspaces.Count)개를 조회했습니다."
        }
        $prefixes = @('') + @($workspaces | ForEach-Object { "/workspaces/$([uri]::EscapeDataString($_.name))" })
        $coverageStart = $results.Count

        if ($CompareFoundryKeys) {
            $account = Read-Arm "https://management.azure.com${FoundryResourceId}?api-version=2024-10-01"
            if ($account.Status -ne '200' -or $account.Data.kind -notin @('OpenAI', 'AIServices')) {
                $keysState = 'Foundry account kind or access could not be verified.'
                $keysStateKo = 'Foundry 계정의 유형 또는 접근 권한을 확인할 수 없습니다.'
            } elseif ($account.Data.properties.disableLocalAuth -eq $true) {
                $keysState = 'Foundry local key authentication is disabled.'
                $keysStateKo = 'Foundry의 로컬 키 인증이 비활성화되어 있습니다.'
                $keysDisabled = $true
            } else {
                $keyResponse = Read-Arm "https://management.azure.com${FoundryResourceId}/listKeys?api-version=2024-10-01" 'POST'
                if ($keyResponse.Status -ne '200' -or $keyResponse.Data.key1 -isnot [string] -or
                    $keyResponse.Data.key2 -isnot [string] -or [string]::IsNullOrWhiteSpace($keyResponse.Data.key1) -or
                    [string]::IsNullOrWhiteSpace($keyResponse.Data.key2)) {
                    $keysState = "Current Foundry keys unavailable ($($keyResponse.Status))."
                    $keysStateKo = "Foundry의 현재 키를 조회할 수 없습니다 ($($keyResponse.Status))."
                } else {
                    $currentKeys = @($keyResponse.Data.key1, $keyResponse.Data.key2)
                }
                $keyResponse = $null
            }
            if (-not $currentKeys) {
                Add-Result 'PolicyFoundryKeyMatch' $ApimResourceId $(if ($keysDisabled) { 'NotApplicable' } else { 'Unknown' }) `
                    $keysState $keysStateKo
            }
        }

        foreach ($prefix in $prefixes) {
            $references.Clear()
            $referenceStart = $results.Count
            Read-ReferenceScope $prefix
            $partial = @($results | Select-Object -Skip $referenceStart | Where-Object Check -eq 'ReferenceCoverage').Count -gt 0
            Read-NamedValueScope $prefix $partial
        }
        $scanPartial = $workspacePartial -or @($results | Select-Object -Skip $coverageStart |
            Where-Object { $_.Check -in @('ReferenceCoverage', 'NamedValueInventory') -and $_.Status -eq 'Unknown' }).Count -gt 0
        Add-Result 'ReferenceCoverage' 'Service and visible workspace scopes' $(if ($scanPartial) { 'Partial' } else { 'StaticOnly' }) `
            'Literal placeholders in visible policy XML and backend properties only; masked values and runtime execution are not verified.' `
            '조회 가능한 정책 XML과 Backend 속성에 명시된 참조만 확인했습니다. 마스킹된 값과 실제 실행 여부는 검증하지 않았습니다.'
        $currentKeys = $null
    }

    $orderedResults = $results | Sort-Object -Stable -Property ApiName, WorkspaceName, ApiRevision, OperationName, ResourceName, Check, Target, ReferencedBy
    if ($PassThru) {
        $orderedResults
    } else {
        $orderedResults | Export-Csv -LiteralPath $OutputPath -Encoding utf8BOM
        $results | Group-Object -Property Check, Status | Select-Object Name, Count
    }
}

Export-ModuleMember -Function Invoke-ApimConfigAudit
