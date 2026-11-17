
$resourceGroupName = 'shared-frontdoor-rg'
$location = 'southafricanorth'
$frontDoorProfileName = 'shared-afd-profile'
$bicepMain = 'frontdoor-deployment.bicep'

az group create `
    --name $resourceGroupName `
    --location $location 

az deployment group create `
    --resource-group $resourceGroupName `
    --name 'shared-frontdoor' `
    --template-file $bicepMain `
    --parameters "frontDoorProfileName=$frontDoorProfileName" `
    --query properties.outputs.frontDoorResourceId.value `
    --output tsv
