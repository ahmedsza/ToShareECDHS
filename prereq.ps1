Install-Module Posh-SSH -Scope CurrentUser

$SubscriptionId = az account show --query id -o tsv
$ResourceGroup = "<RESOURCE_GROUP_NAME>"

az policy assignment list --query "[?policyDefinitionId=='Deny-Subnet-Without-Nsg'].name" --output tsv

az policy exemption create `
  --name "DenySubnetNsgWaiver" `
  --policy-assignment "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/policyAssignments/<ASSIGNMENT_ID>" `
  --exemption-category "Waiver" `
  --scope "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" `
  --display-name "Exemption for subnet without NSG" `

az policy assignment list --query "[?policyDefinitionId=='Deny-PublicPaaSEndpoints'].name" --output tsv

  az policy exemption create `
  --name "exempt-public-paas-waiver" `
  --policy-assignment "Deny-PublicPaaSEndpoints" `
  --exemption-category "Waiver" `
  --scope "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" `
  --description "Exempting this resource group due to explicit business need for public ingress." 
