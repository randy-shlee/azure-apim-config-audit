#requires -Version 7.2
[CmdletBinding(DefaultParameterSetName = 'ById', PositionalBinding = $false)]
param(
    [Parameter(Mandatory, ParameterSetName = 'ById', Position = 0)][string]$ApimResourceId,
    [Parameter(Mandatory, ParameterSetName = 'ByGroup')][Alias('RgName')]
    [ValidatePattern('^[\p{L}\p{N}_.()-]+$')][string]$ResourceGroupName,
    [Parameter(Mandatory, ParameterSetName = 'ByName')]
    [ValidatePattern('^[a-z][a-z0-9-]*$')][string]$ApimName,
    [Parameter(ParameterSetName = 'ByGroup')][Parameter(ParameterSetName = 'ByName')]
    [guid]$SubscriptionId,
    [string]$OutputPath = '.\apim-audit.csv',
    [string]$FoundryResourceId,
    [switch]$CompareFoundryKeys,
    [switch]$CompareLabFixture
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ApimAudit.psm1') -Force

if ($PSCmdlet.ParameterSetName -eq 'ById') {
    $serviceIds = @($ApimResourceId)
} else {
    $scope = @()
    if ($PSBoundParameters.ContainsKey('SubscriptionId')) { $scope = @('--subscription', "$SubscriptionId") }
    $subscription = az account show @scope --query id -o tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or $subscription -notmatch '^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$') {
        throw 'Azure CLI could not resolve the subscription. Run az login or provide -SubscriptionId.'
    }

    $group = @()
    if ($ResourceGroupName) { $group = @('--resource-group', $ResourceGroupName) }
    $json = az apim list --subscription $subscription @group --query '[].{id:id,name:name}' -o json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI could not list APIM services in the requested scope.' }
    $services = ($json -join "`n") | ConvertFrom-Json -AsHashtable -NoEnumerate
    if ($services -isnot [array]) { throw 'Azure CLI returned an invalid APIM service list.' }
    if ($ApimName) { $services = @($services | Where-Object { $_.name -eq $ApimName }) }
    $serviceIds = @($services | ForEach-Object {
        if (-not $_.id) { throw 'Azure CLI returned an APIM service without a resource ID.' }
        $_.id
    } | Sort-Object -Unique)
    if (-not $serviceIds.Count) { throw "No matching APIM service found in subscription $subscription." }
    if ($ApimName -and $serviceIds.Count -ne 1) { throw 'APIM name matched multiple services. Provide a resource ID instead.' }
}

if ($serviceIds.Count -gt 1 -and ($CompareLabFixture -or $CompareFoundryKeys)) {
    throw 'Credential comparison requires a single APIM service. Provide -ApimName or -ApimResourceId.'
}
$rows = foreach ($serviceId in $serviceIds) {
    Invoke-ApimConfigAudit -ApimResourceId $serviceId -PassThru `
        -FoundryResourceId $FoundryResourceId -CompareFoundryKeys:$CompareFoundryKeys -CompareLabFixture:$CompareLabFixture
}
$rows | Export-Csv -LiteralPath $OutputPath -Encoding utf8BOM
$rows | Group-Object -Property Check, Status | Select-Object Name, Count
