$ErrorActionPreference = 'Stop'
$resourceGroupName = 'ahms-wp-ec5-dev-rg'
$parameterFileName = 'wordpress-deployment-arm-template.dev.parameters.json'
$bicepMain = 'wordpress-deployment-arm-template.bicep'
$bicepParamsFile =  $parameterFileName
$deploymentName = "wordpress-$(Get-Date -Format 'yyyyMMddHHmmss')"
$location = 'southafricanorth'
$frontDoorResourceGroupName = 'shared-frontdoor-rg'
$frontDoorProfileName = 'shared-afd-profile'

$deploymentParameters = "@$bicepParamsFile"

$profile = Get-Content -LiteralPath $bicepParamsFile -Raw | ConvertFrom-Json -AsHashtable
$frontDoorResourceId = ''
if (-not $profile.parameters.ContainsKey('setupFrontDoorRoutes') -or $profile.parameters.setupFrontDoorRoutes.value) {
    $frontDoorResourceId = az afd profile show `
        --resource-group $frontDoorResourceGroupName `
        --profile-name $frontDoorProfileName `
        --query id --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $frontDoorResourceId) { throw 'Front Door lookup failed.' }
}

Write-Host $frontDoorResourceId
az group create `
    --name $resourceGroupName `
    --location $location `
    --tags SecurityControl=Ignore




az deployment group create `
    --resource-group $resourceGroupName `
    --name $deploymentName `
    --template-file $bicepMain `
    --parameters $deploymentParameters "frontDoorResourceId=$frontDoorResourceId"

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