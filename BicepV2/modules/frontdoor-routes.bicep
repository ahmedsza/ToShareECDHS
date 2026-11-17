@minLength(1)
param frontDoorProfileName string
param siteResourceName string
param frontDoorEndpointName string
param frontDoorBlobEndpointName string
param appServiceHostName string
param enableBlobStorage bool = false
param storageAccountName string = ''
param blobContainerName string
param enableFrontDoorCaching bool = true
param frontDoorHealthProbePath string = '/'
@allowed([
  30
  60
  100
])
param frontDoorHealthProbeIntervalInSeconds int = 100
@allowed([
  'Detection'
  'Prevention'
])
param frontDoorWafMode string = 'Prevention'
param tags object = {}

var frontDoorOriginGroupName = '${siteResourceName}-wordpress'
var frontDoorBlobOriginGroupName = '${siteResourceName}-media'
var frontDoorWafPolicyName = replace(siteResourceName, '-', '')

resource frontDoorProfile 'Microsoft.Cdn/profiles@2023-05-01' existing = {
  name: frontDoorProfileName
}

resource frontDoorEndpoint 'Microsoft.Cdn/profiles/afdEndpoints@2023-05-01' = {
  parent: frontDoorProfile
  name: frontDoorEndpointName
  location: 'global'
  properties: {
    enabledState: 'Enabled'
  }
}

resource frontDoorOriginGroup 'Microsoft.Cdn/profiles/originGroups@2023-05-01' = {
  parent: frontDoorProfile
  name: frontDoorOriginGroupName
  properties: {
    healthProbeSettings: {
      probePath: frontDoorHealthProbePath
      probeRequestType: 'GET'
      probeProtocol: 'Https'
      probeIntervalInSeconds: frontDoorHealthProbeIntervalInSeconds
    }
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 0
    }
    sessionAffinityState: 'Disabled'
  }
}

resource frontDoorOrigin 'Microsoft.Cdn/profiles/originGroups/origins@2023-05-01' = {
  parent: frontDoorOriginGroup
  name: 'wordpress-app-service'
  properties: {
    hostName: appServiceHostName
    originHostHeader: appServiceHostName
    httpPort: 80
    httpsPort: 443
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
    enforceCertificateNameCheck: true
  }
}

resource frontDoorRoute 'Microsoft.Cdn/profiles/afdEndpoints/routes@2023-05-01' = {
  parent: frontDoorEndpoint
  name: 'wordpress'
  properties: {
    originGroup: {
      id: frontDoorOriginGroup.id
    }
    supportedProtocols: [
      'Https'
    ]
    patternsToMatch: [
      '/*'
    ]
    forwardingProtocol: 'HttpsOnly'
    httpsRedirect: 'Enabled'
    linkToDefaultDomain: 'Enabled'
    enabledState: 'Enabled'
    cacheConfiguration: enableFrontDoorCaching ? {
      queryStringCachingBehavior: 'UseQueryString'
    } : null
  }
  dependsOn: [
    frontDoorOrigin
  ]
}

resource frontDoorBlobEndpoint 'Microsoft.Cdn/profiles/afdEndpoints@2023-05-01' = if (enableBlobStorage) {
  parent: frontDoorProfile
  name: frontDoorBlobEndpointName
  location: 'global'
  properties: {
    enabledState: 'Enabled'
  }
}

resource frontDoorBlobOriginGroup 'Microsoft.Cdn/profiles/originGroups@2023-05-01' = if (enableBlobStorage) {
  parent: frontDoorProfile
  name: frontDoorBlobOriginGroupName
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 0
    }
    sessionAffinityState: 'Disabled'
  }
}

resource frontDoorBlobOrigin 'Microsoft.Cdn/profiles/originGroups/origins@2023-05-01' = if (enableBlobStorage) {
  parent: frontDoorBlobOriginGroup
  name: 'wordpress-blob-storage'
  properties: {
    hostName: '${storageAccountName}.blob.${environment().suffixes.storage}'
    originHostHeader: '${storageAccountName}.blob.${environment().suffixes.storage}'
    httpPort: 80
    httpsPort: 443
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
    enforceCertificateNameCheck: true
  }
}

resource frontDoorBlobRoute 'Microsoft.Cdn/profiles/afdEndpoints/routes@2023-05-01' = if (enableBlobStorage) {
  parent: frontDoorBlobEndpoint
  name: 'wordpress-blob'
  properties: {
    originGroup: {
      id: frontDoorBlobOriginGroup!.id
    }
    originPath: '/'
    supportedProtocols: [
      'Http'
      'Https'
    ]
    patternsToMatch: [
      '/${blobContainerName}/wp-content/uploads/*'
    ]
    forwardingProtocol: 'HttpsOnly'
    httpsRedirect: 'Enabled'
    linkToDefaultDomain: 'Enabled'
    enabledState: 'Enabled'
    cacheConfiguration: enableFrontDoorCaching ? {
      queryStringCachingBehavior: 'UseQueryString'
      compressionSettings: {
        isCompressionEnabled: true
        contentTypesToCompress: [
          'image/svg+xml'
          'text/plain'
        ]
      }
    } : null
  }
  dependsOn: [
    frontDoorBlobOrigin
  ]
}

resource frontDoorMediaRoute 'Microsoft.Cdn/profiles/afdEndpoints/routes@2023-05-01' = if (enableBlobStorage) {
  parent: frontDoorEndpoint
  name: 'wordpress-media'
  properties: {
    originGroup: {
      id: frontDoorBlobOriginGroup!.id
    }
    originPath: '/${blobContainerName}/wp-content/uploads'
    supportedProtocols: [
      'Https'
    ]
    patternsToMatch: [
      '/wp-content/uploads/*'
    ]
    forwardingProtocol: 'HttpsOnly'
    httpsRedirect: 'Enabled'
    linkToDefaultDomain: 'Enabled'
    enabledState: 'Enabled'
    cacheConfiguration: enableFrontDoorCaching ? {
      queryStringCachingBehavior: 'UseQueryString'
    } : null
  }
  dependsOn: [
    frontDoorBlobOrigin
  ]
}

resource frontDoorWafPolicy 'Microsoft.Network/frontdoorwebapplicationfirewallpolicies@2024-02-01' = {
  name: frontDoorWafPolicyName
  location: 'global'
  tags: tags
  sku: {
    name: 'Standard_AzureFrontDoor'
  }
  properties: {
    policySettings: {
      enabledState: 'Enabled'
      mode: frontDoorWafMode
      requestBodyCheck: 'Enabled'
    }
  }
}

resource frontDoorSecurityPolicy 'Microsoft.Cdn/profiles/securityPolicies@2023-05-01' = {
  parent: frontDoorProfile
  name: '${siteResourceName}-waf'
  properties: {
    parameters: {
      type: 'WebApplicationFirewall'
      wafPolicy: {
        id: frontDoorWafPolicy.id
      }
      associations: [
        {
          domains: concat([
            {
              id: frontDoorEndpoint.id
            }
          ], enableBlobStorage ? [
            {
              id: frontDoorBlobEndpoint!.id
            }
          ] : [])
          patternsToMatch: [
            '/*'
          ]
        }
      ]
    }
  }
}

output frontDoorId string = frontDoorProfile.properties.frontDoorId
output frontDoorEndpointHostName string = frontDoorEndpoint.properties.hostName
output frontDoorBlobEndpointHostName string = enableBlobStorage ? frontDoorBlobEndpoint!.properties.hostName : ''
output frontDoorBlobMediaBaseUrl string = enableBlobStorage ? 'https://${frontDoorBlobEndpoint!.properties.hostName}/${blobContainerName}/wp-content/uploads' : ''
