param storageAccountName string
param blobContainerName string
param blobPublicAccessLevel string
param blobSoftDeleteRetentionDays int
param containerSoftDeleteRetentionDays int
@minValue(1)
@maxValue(3650)
param blobVersionRetentionDays int = 90

resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: storageAccountName
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    restorePolicy: {
      enabled: false
    }
    deleteRetentionPolicy: {
      enabled: true
      days: blobSoftDeleteRetentionDays
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: containerSoftDeleteRetentionDays
    }
    changeFeed: {
      enabled: false
    }
    isVersioningEnabled: true
  }
}

resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobService
  name: blobContainerName
  properties: {
    immutableStorageWithVersioning: {
      enabled: false
    }
    metadata: {}
    publicAccess: blobPublicAccessLevel
  }
}

resource mediaVersionRetention 'Microsoft.Storage/storageAccounts/managementPolicies@2024-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'expire-previous-media-versions'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: [
                'blockBlob'
              ]
              prefixMatch: [
                '${blobContainerName}/'
              ]
            }
            actions: {
              version: {
                delete: {
                  daysAfterCreationGreaterThan: blobVersionRetentionDays
                }
              }
            }
          }
        }
      ]
    }
  }
  dependsOn: [
    blobService
  ]
}
