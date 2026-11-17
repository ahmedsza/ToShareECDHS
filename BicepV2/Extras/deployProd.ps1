$ErrorActionPreference = 'Stop'
$resourceGroupName = 'ahms-wg-prod-rg'
$parameterFileName = 'wordpress-ecdhs.prod.parameters'
$bicepMain = 'wordpress-deployment.bicep'
$bicepParamsFile = Join-Path $PSScriptRoot $parameterFileName
$deploymentName = "wordpress-$(Get-Date -Format 'yyyyMMddHHmmss')"
$location = 'southafricanorth'

$deploymentParameters = "@$bicepParamsFile"

function Assert-FrontDoorConfiguration {
    param([hashtable] $Parameters)
    $setupRoutes = $true
    if ($Parameters.ContainsKey('setupFrontDoorRoutes')) {
        $setupRoutes = $Parameters.setupFrontDoorRoutes.value
        if ($setupRoutes -isnot [bool]) { throw 'setupFrontDoorRoutes must be a JSON boolean.' }
    }
    if (-not $setupRoutes) { return }
    $profileId = if ($Parameters.ContainsKey('frontDoorResourceId')) { $Parameters.frontDoorResourceId.value } else { '' }
    if ($profileId -notmatch '^/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/resourceGroups/[^/<>]+/providers/Microsoft\.Cdn/profiles/[^/<>]+$') {
        throw 'Deploy frontdoor-deployment.bicep first and set frontDoorResourceId to its full frontDoorResourceId output, or set setupFrontDoorRoutes=false.'
    }
}

$profile = Get-Content -LiteralPath $bicepParamsFile -Raw | ConvertFrom-Json -AsHashtable
Assert-FrontDoorConfiguration -Parameters $profile.parameters

az group create `
    --name $resourceGroupName `
    --location $location




az deployment group create `
    --resource-group $resourceGroupName `
    --name $deploymentName `
    --template-file $bicepMain `
    --parameters $deploymentParameters

Write-Host 'Resource group creation and deployment completed.'

$keyVaultName = az deployment group show `
    --resource-group $resourceGroupName `
    --name $deploymentName `
    --query properties.outputs.keyVaultNameOutput.value `
    --output tsv


az group delete  --name $resourceGroupName --yes

# The vault name is now stable, so the soft-deleted vault must be purged before the next run.
if ($keyVaultName) {
    az keyvault purge --name $keyVaultName --location $location
}