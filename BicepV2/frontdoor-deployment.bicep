targetScope = 'resourceGroup'

@description('Name of the shared Azure Front Door Standard profile.')
@minLength(1)
param frontDoorProfileName string
param tags object = {}
@description('Existing Log Analytics workspace resource ID. Leave empty to create a workspace for shared profile diagnostics in this resource group.')
param logAnalyticsWorkspaceResourceId string = ''

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (empty(logAnalyticsWorkspaceResourceId)) {
  name: 'law-${uniqueString(resourceGroup().id, frontDoorProfileName)}'
  location: resourceGroup().location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

var diagnosticsWorkspaceResourceId = empty(logAnalyticsWorkspaceResourceId) ? logAnalyticsWorkspace.id : logAnalyticsWorkspaceResourceId

resource frontDoorProfile 'Microsoft.Cdn/profiles@2023-05-01' = {
  name: frontDoorProfileName
  location: 'global'
  tags: tags
  sku: {
    name: 'Standard_AzureFrontDoor'
  }
}

resource frontDoorDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: frontDoorProfile
  name: 'send-to-log-analytics'
  properties: {
    workspaceId: diagnosticsWorkspaceResourceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output frontDoorResourceId string = frontDoorProfile.id
output frontDoorId string = frontDoorProfile.properties.frontDoorId
output diagnosticsWorkspaceResourceId string = diagnosticsWorkspaceResourceId
