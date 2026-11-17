
$resourceGroupName = ''
$parameterFileName = 'wordpress-ecdhs.prod.parameters.json'
$bicepMain = 'wordpress-deployment.bicep'
$bicepParamsFile =  $parameterFileName
$deploymentName = "wordpress-$(Get-Date -Format 'yyyyMMddHHmmss')"
$location = 'southafricanorth'
$frontDoorResourceGroupName = 'shared-frontdoor-rg'
$frontDoorProfileName = 'shared-afd-profile'

$deploymentParameters = "@$bicepParamsFile"


$frontDoorResourceId = az afd profile show `
        --resource-group $frontDoorResourceGroupName `
        --profile-name $frontDoorProfileName `
        --query id --output tsv
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


