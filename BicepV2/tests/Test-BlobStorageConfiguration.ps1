[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$bicepDirectory = Split-Path $PSScriptRoot -Parent
$compiledTemplate = az bicep build --file (Join-Path $bicepDirectory 'wordpress-deployment.bicep') --stdout
if ($LASTEXITCODE -ne 0) { throw 'Bicep compilation failed.' }
$template = ($compiledTemplate -join [Environment]::NewLine) | ConvertFrom-Json -AsHashtable
$resources = $template.resources
$routingTemplate = $resources.frontDoorRoutes.properties.template
$assertions = [Collections.Generic.List[string]]::new()

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
    $assertions.Add($Message)
}

function Assert-Equal {
    param($Actual, $Expected, [string] $Message)
    Assert-True ($Actual -ceq $Expected) $Message
}

function Get-RoutingResource {
    param([string] $Type, [string] $NameMarker)
    $moduleResources = $routingTemplate.resources
    if ($moduleResources -is [System.Collections.IDictionary]) { $moduleResources = $moduleResources.Values }
    $matches = @($moduleResources | Where-Object { $_.type -ieq $Type -and $_.name.Contains($NameMarker) })
    Assert-Equal $matches.Count 1 "Exactly one routing resource must match $Type / $NameMarker."
    return $matches[0]
}

$routingResources = @{
    frontDoorEndpoint = Get-RoutingResource 'Microsoft.Cdn/profiles/afdEndpoints' "'frontDoorEndpointName'"
    frontDoorBlobEndpoint = Get-RoutingResource 'Microsoft.Cdn/profiles/afdEndpoints' "'frontDoorBlobEndpointName'"
    frontDoorOriginGroup = Get-RoutingResource 'Microsoft.Cdn/profiles/originGroups' "'frontDoorOriginGroupName'"
    frontDoorBlobOriginGroup = Get-RoutingResource 'Microsoft.Cdn/profiles/originGroups' "'frontDoorBlobOriginGroupName'"
    frontDoorOrigin = Get-RoutingResource 'Microsoft.Cdn/profiles/originGroups/origins' "'wordpress-app-service'"
    frontDoorBlobOrigin = Get-RoutingResource 'Microsoft.Cdn/profiles/originGroups/origins' "'wordpress-blob-storage'"
    frontDoorRoute = Get-RoutingResource 'Microsoft.Cdn/profiles/afdEndpoints/routes' "'wordpress'"
    frontDoorBlobRoute = Get-RoutingResource 'Microsoft.Cdn/profiles/afdEndpoints/routes' "'wordpress-blob'"
    frontDoorMediaRoute = Get-RoutingResource 'Microsoft.Cdn/profiles/afdEndpoints/routes' "'wordpress-media'"
    frontDoorWafPolicy = Get-RoutingResource 'Microsoft.Network/frontdoorwebapplicationfirewallpolicies' "'frontDoorWafPolicyName'"
    frontDoorSecurityPolicy = Get-RoutingResource 'Microsoft.Cdn/profiles/securityPolicies' "'siteResourceName'"
}

Assert-Equal $template.parameters.enableBlobStorage.type 'bool' 'Blob integration must use a boolean parameter.'
Assert-Equal $template.parameters.enableBlobStorage.defaultValue $false 'Blob integration must default to disabled.'
foreach ($resourceName in @('storageAccount', 'storageResources', 'storageBlobDataContributor', 'storagePrivateDnsZone', 'storagePrivateDnsLink', 'storagePrivateEndpoint', 'storagePrivateDnsZoneGroup', 'blobDiagnostics')) {
    Assert-Equal $resources[$resourceName].condition "[parameters('enableBlobStorage')]" "$resourceName must only deploy when Blob storage is enabled."
}
foreach ($resourceName in @('frontDoorBlobEndpoint', 'frontDoorBlobOriginGroup', 'frontDoorBlobOrigin', 'frontDoorBlobRoute', 'frontDoorMediaRoute')) {
    Assert-Equal $routingResources[$resourceName].condition "[parameters('enableBlobStorage')]" "$resourceName must only deploy when Blob storage is enabled."
}
foreach ($resourceName in @('managedIdentity', 'vnet', 'keyVaultPrivateEndpoint', 'appServiceConfiguration')) {
    Assert-True (-not $resources[$resourceName].ContainsKey('condition')) "$resourceName must remain available when Blob storage is disabled."
}
foreach ($resourceName in @('frontDoorEndpoint', 'frontDoorRoute', 'frontDoorSecurityPolicy')) {
    Assert-True (-not $routingResources[$resourceName].ContainsKey('condition')) "$resourceName must remain available inside enabled routing when Blob storage is disabled."
}
$storage = $resources.storageAccount.properties
Assert-Equal $storage.allowBlobPublicAccess $true 'The enabled media account must allow anonymous blob reads.'
Assert-Equal $storage.publicNetworkAccess 'Enabled' 'Public media must be reachable by Front Door and anonymous clients.'
Assert-Equal $storage.networkAcls.defaultAction 'Allow' 'The storage firewall must permit public media reads.'
Assert-Equal $resources.storageAccount.tags "[union(variables('resourceTags'), createObject('securitycontrol', 'ignore'))]" 'The storage account must carry securitycontrol=ignore while retaining workload tags.'
Assert-Equal $storage.networkAcls.bypass 'None' 'No storage firewall bypass should be introduced.'
Assert-Equal $storage.allowSharedKeyAccess $false 'Shared Key access must stay disabled.'
Assert-Equal $resources.storageResources.properties.parameters.blobPublicAccessLevel.value 'Blob' 'The media container must allow individual blob reads, not anonymous listing.'

$storageResources = $resources.storageResources.properties.template.resources
$container = $storageResources | Where-Object { $_.type -eq 'Microsoft.Storage/storageAccounts/blobServices/containers' }
Assert-Equal $container.properties.publicAccess "[parameters('blobPublicAccessLevel')]" 'The container must apply the selected access level.'
$blobService = $storageResources | Where-Object { $_.type -eq 'Microsoft.Storage/storageAccounts/blobServices' }
Assert-Equal $blobService.properties.isVersioningEnabled $true 'Blob versioning must be retained.'
$retention = $storageResources | Where-Object { $_.type -eq 'Microsoft.Storage/storageAccounts/managementPolicies' }
$retentionRule = $retention.properties.policy.rules[0].definition
Assert-True ($retentionRule.actions.Count -eq 1 -and $retentionRule.actions.ContainsKey('version')) 'Lifecycle deletion must remain limited to previous versions.'
Assert-Equal $retentionRule.filters.prefixMatch[0] "[format('{0}/', parameters('blobContainerName'))]" 'Version retention must remain scoped to the media container.'

$appModule = $resources.appServiceConfiguration.properties
Assert-Equal $appModule.parameters.enableBlobStorage.value "[parameters('enableBlobStorage')]" 'The root opt-in must reach the App Service module.'
Assert-Equal $appModule.parameters.storageAccountName "[if(parameters('enableBlobStorage'), createObject('value', variables('storageAccountName')), createObject('value', ''))]" 'The disabled app must receive an empty storage account name.'
Assert-True ($appModule.parameters.frontDoorBlobEndpointHostName.StartsWith("[if(and(parameters('setupFrontDoorRoutes'), parameters('enableBlobStorage')),")) 'The disabled app must not evaluate a routing module Blob output.'
$webConfiguration = $appModule.template.resources | Where-Object { $_.type -eq 'Microsoft.Web/sites/config' }
$appSettings = $webConfiguration.properties.appSettings
Assert-Equal $template.parameters.enableRedis.type 'bool' 'Redis must use a boolean opt-in.'
Assert-Equal $template.parameters.enableRedis.defaultValue $false 'Redis must be disabled by default.'
foreach ($resourceName in @('redis', 'redisDatabase', 'redisPrimaryKeySecret', 'redisPrivateDnsZone', 'redisPrivateDnsLink', 'redisPrivateEndpoint', 'redisPrivateDnsZoneGroup', 'redisDiagnostics', 'redisDatabaseDiagnostics')) {
    Assert-Equal $resources[$resourceName].condition "[parameters('enableRedis')]" "$resourceName must only deploy when Redis is enabled."
}
Assert-Equal $appModule.parameters.enableRedis.value "[parameters('enableRedis')]" 'The Redis switch must reach the App Service module.'
Assert-True ($resources.redisPrimaryKeySecret.properties.value.StartsWith("[if(parameters('enableRedis'),")) 'A disabled Redis database must never trigger listKeys evaluation.'
Assert-True ($appModule.parameters.redisHostName.Contains("if(parameters('enableRedis')")) 'A disabled Redis instance must not be referenced for its hostname.'
Assert-True ($template.outputs.redisDatabaseHostName.value.Contains("if(parameters('enableRedis')")) 'The Redis output must be conditional.'
Assert-True ($appSettings.Contains("if(parameters('enableRedis'), createArray(createObject('name', 'REDIS_HOST'")) 'Redis settings must be in an independently conditional branch.'
foreach ($settingName in @('REDIS_HOST', 'REDIS_PORT', 'REDIS_PASSWORD', 'WP_REDIS_HOST', 'WP_REDIS_PASSWORD')) {
    Assert-Equal ([regex]::Matches($appSettings, [regex]::Escape("'name', '$settingName'")).Count) 1 "The setting $settingName must occur only once."
}
Assert-True ($appSettings.Contains("createObject('name', 'BLOB_STORAGE_ENABLED', 'value', string(parameters('enableBlobStorage')))") ) 'The image enablement flag must follow the parameter.'
$blobSettings = "if(parameters('enableBlobStorage'), createArray(createObject('name', 'STORAGE_ACCOUNT_NAME', 'value', parameters('storageAccountName')), createObject('name', 'BLOB_CONTAINER_NAME', 'value', parameters('blobContainerName')), createObject('name', 'BLOB_STORAGE_URL', 'value', format('{0}.blob.{1}', parameters('storageAccountName'), environment().suffixes.storage)), createObject('name', 'ENABLE_BLOB_MANAGED_IDENTITY', 'value', 'true')), createArray())"
Assert-True ($appSettings.Contains($blobSettings)) 'All Blob-specific settings must be in the enabled branch with an empty disabled branch.'
foreach ($settingName in @('STORAGE_ACCOUNT_NAME', 'BLOB_CONTAINER_NAME', 'BLOB_STORAGE_URL', 'ENABLE_BLOB_MANAGED_IDENTITY', 'WPAT_BLOB_CDN_HOST')) {
    Assert-Equal ([regex]::Matches($appSettings, [regex]::Escape("'name', '$settingName'")).Count) 1 "The setting $settingName must not also occur outside its opt-in branch."
}
Assert-True (-not $appSettings.Contains('STORAGE_ACCOUNT_KEY')) 'No storage key may be injected into app settings.'
Assert-True ($appSettings.Contains("createObject('name', 'ENTRA_CLIENT_ID'")) 'The shared managed identity must remain configured.'
Assert-Equal $template.parameters.enableEmail.defaultValue $false 'Email must remain disabled by default.'
Assert-True ($appSettings.Contains("if(parameters('enableEmail'), createArray(createObject('name', 'WP_EMAIL_CONNECTION_STRING'")) 'Email settings must remain independently conditional.'
$adminEmail = $webConfiguration.properties.connectionStrings | Where-Object { $_.name -eq 'WORDPRESS_ADMIN_EMAIL' }
Assert-Equal $adminEmail.connectionString "[parameters('wordpressAdminEmail')]" 'Administrator email must remain independent of outbound email.'

$origin = $routingResources.frontDoorBlobOrigin.properties
Assert-Equal $origin.hostName "[format('{0}.blob.{1}', parameters('storageAccountName'), environment().suffixes.storage)]" 'The media origin must use the normal Blob hostname.'
Assert-Equal $origin.originHostHeader $origin.hostName 'The Blob host header must match its origin.'
Assert-Equal $origin.enforceCertificateNameCheck $true 'Blob TLS certificate validation must stay enabled.'
$blobRoute = $routingResources.frontDoorBlobRoute.properties
Assert-Equal $blobRoute.originGroup.id "[resourceId('Microsoft.Cdn/profiles/originGroups', parameters('frontDoorProfileName'), variables('frontDoorBlobOriginGroupName'))]" 'The dedicated endpoint must route to its site-specific Blob origin group.'
Assert-Equal $blobRoute.originPath '/' 'The dedicated endpoint must use a valid root origin path without duplicating the container name.'
Assert-Equal $blobRoute.patternsToMatch.Count 1 'The Blob endpoint must expose only the configured media path.'
Assert-Equal $blobRoute.patternsToMatch[0] "[format('/{0}/wp-content/uploads/*', parameters('blobContainerName'))]" 'The media endpoint path must match W3 Total Cache URLs.'
Assert-Equal $blobRoute.forwardingProtocol 'HttpsOnly' 'The Blob endpoint must use HTTPS to the origin.'
Assert-Equal $blobRoute.httpsRedirect 'Enabled' 'The Blob endpoint must redirect HTTP clients to HTTPS.'
Assert-Equal $blobRoute.cacheConfiguration "[if(parameters('enableFrontDoorCaching'), createObject('queryStringCachingBehavior', 'UseQueryString', 'compressionSettings', createObject('isCompressionEnabled', true(), 'contentTypesToCompress', createArray('image/svg+xml', 'text/plain'))), null())]" 'The Blob route must conditionally enable caching while preserving version query strings and compression.'
Assert-Equal $routingResources.frontDoorSecurityPolicy.properties.parameters.associations[0].domains "[concat(createArray(createObject('id', resourceId('Microsoft.Cdn/profiles/afdEndpoints', parameters('frontDoorProfileName'), parameters('frontDoorEndpointName')))), if(parameters('enableBlobStorage'), createArray(createObject('id', resourceId('Microsoft.Cdn/profiles/afdEndpoints', parameters('frontDoorProfileName'), parameters('frontDoorBlobEndpointName')))), createArray()))]" 'The website must always have WAF coverage; the Blob endpoint must only be associated when enabled.'
foreach ($outputName in @('frontDoorBlobEndpointHostName', 'frontDoorBlobMediaBaseUrl')) {
    Assert-Equal $template.outputs[$outputName].type 'string' "$outputName must retain its string output contract."
    Assert-True ($template.outputs[$outputName].value.StartsWith("[if(and(parameters('setupFrontDoorRoutes'), parameters('enableBlobStorage')),") -and $template.outputs[$outputName].value.EndsWith(", '')]")) "$outputName must be empty when Blob storage or routing is disabled."
}
Assert-True ($template.outputs.storageAccountNameOutput.value.StartsWith("[if(parameters('enableBlobStorage'),")) 'Storage output must remain independent of Front Door setup.'
Assert-True ($template.outputs.ContainsKey('frontDoorBlobMediaBaseUrl')) 'Deployment must expose the full Front Door media URL.'
$route = $routingResources.frontDoorMediaRoute
Assert-Equal $route.properties.originGroup.id "[resourceId('Microsoft.Cdn/profiles/originGroups', parameters('frontDoorProfileName'), variables('frontDoorBlobOriginGroupName'))]" 'The optional uploads route must target Blob storage only.'
Assert-Equal $route.properties.originPath "[format('/{0}/wp-content/uploads', parameters('blobContainerName'))]" 'The Blob uploads route must retain the container and uploads prefix.'
Assert-Equal $route.properties.patternsToMatch.Count 1 'The media route must have one bounded path pattern.'
Assert-Equal $route.properties.patternsToMatch[0] '/wp-content/uploads/*' 'Only WordPress uploads may use the media route.'
Assert-Equal $route.properties.forwardingProtocol 'HttpsOnly' 'Media origin requests must use HTTPS.'
Assert-Equal $route.properties.cacheConfiguration "[if(parameters('enableFrontDoorCaching'), createObject('queryStringCachingBehavior', 'UseQueryString'), null())]" 'The uploads route must follow the shared caching switch.'
Assert-Equal $routingResources.frontDoorRoute.properties.patternsToMatch[0] '/*' 'All other requests must retain the WordPress route.'
Assert-Equal $template.parameters.enableFrontDoorCaching.type 'bool' 'Front Door caching must use a boolean parameter.'
Assert-Equal $template.parameters.enableFrontDoorCaching.defaultValue $true 'Front Door caching must default to enabled.'
Assert-Equal $routingResources.frontDoorRoute.properties.cacheConfiguration "[if(parameters('enableFrontDoorCaching'), createObject('queryStringCachingBehavior', 'UseQueryString'), null())]" 'The WordPress route must enable query-string-aware caching only when requested, and disable caching otherwise.'

$sharedBuild = az bicep build --file (Join-Path $bicepDirectory 'frontdoor-deployment.bicep') --stdout
if ($LASTEXITCODE -ne 0) { throw 'Shared Front Door compilation failed.' }
$sharedTemplate = ($sharedBuild -join [Environment]::NewLine) | ConvertFrom-Json -AsHashtable
$sharedResources = $sharedTemplate.resources
if ($sharedResources -is [System.Collections.IDictionary]) { $sharedResources = @($sharedResources.Values) }
$sharedProfiles = @($sharedResources | Where-Object { $_.type -ieq 'Microsoft.Cdn/profiles' })
Assert-Equal $sharedProfiles.Count 1 'The standalone template must create exactly one shared profile.'
Assert-Equal $sharedProfiles[0].sku.name 'Standard_AzureFrontDoor' 'The shared profile must retain the Standard SKU.'
Assert-Equal $sharedResources.Count 3 'The standalone template must contain only the profile, conditional workspace, and diagnostics.'
$sharedWorkspaces = @($sharedResources | Where-Object { $_.type -ieq 'Microsoft.OperationalInsights/workspaces' })
Assert-Equal $sharedWorkspaces.Count 1 'The standalone template must declare exactly one fallback workspace.'
Assert-Equal $sharedTemplate.parameters.logAnalyticsWorkspaceResourceId.defaultValue '' 'Omitting the workspace ID must default to creating a workspace.'
Assert-Equal $sharedWorkspaces[0].condition "[empty(parameters('logAnalyticsWorkspaceResourceId'))]" 'A workspace must be created only when no existing workspace ID is supplied.'
Assert-Equal $sharedWorkspaces[0].location '[resourceGroup().location]' 'The fallback workspace must use the shared resource group region.'
Assert-Equal $sharedWorkspaces[0].properties.sku.name 'PerGB2018' 'The fallback workspace must use pay-as-you-go pricing.'
Assert-Equal $sharedWorkspaces[0].properties.retentionInDays 30 'The fallback workspace must retain logs for 30 days.'
$workspaceResourceIdExpression = "resourceId('Microsoft.OperationalInsights/workspaces', format('law-{0}', uniqueString(resourceGroup().id, parameters('frontDoorProfileName'))))"
Assert-Equal $sharedTemplate.variables.diagnosticsWorkspaceResourceId "[if(empty(parameters('logAnalyticsWorkspaceResourceId')), $workspaceResourceIdExpression, parameters('logAnalyticsWorkspaceResourceId'))]" 'Diagnostics must select the created workspace for an empty ID and otherwise reuse the supplied ID.'
$sharedDiagnostics = @($sharedResources | Where-Object { $_.type -ieq 'Microsoft.Insights/diagnosticSettings' })
Assert-Equal $sharedDiagnostics.Count 1 'The shared profile must have exactly one diagnostic setting.'
Assert-True (-not $sharedDiagnostics[0].ContainsKey('condition')) 'Shared diagnostics must always be deployed.'
Assert-Equal $sharedDiagnostics[0].scope "[resourceId('Microsoft.Cdn/profiles', parameters('frontDoorProfileName'))]" 'Diagnostics must target the shared profile.'
Assert-Equal $sharedDiagnostics[0].properties.workspaceId "[variables('diagnosticsWorkspaceResourceId')]" 'Diagnostics must send data to the selected workspace.'
Assert-True ($sharedDiagnostics[0].dependsOn -contains "[$workspaceResourceIdExpression]") 'Diagnostics must wait for fallback workspace creation.'
Assert-Equal $sharedDiagnostics[0].properties.logs[0].categoryGroup 'allLogs' 'All Front Door log categories must be collected.'
Assert-Equal $sharedDiagnostics[0].properties.logs[0].enabled $true 'Front Door logs must be enabled.'
Assert-Equal $sharedDiagnostics[0].properties.metrics[0].category 'AllMetrics' 'All Front Door metrics must be collected.'
Assert-Equal $sharedDiagnostics[0].properties.metrics[0].enabled $true 'Front Door metrics must be enabled.'
Assert-Equal $sharedTemplate.outputs.diagnosticsWorkspaceResourceId.value "[variables('diagnosticsWorkspaceResourceId')]" 'The shared deployment must output the selected workspace ID.'
Assert-Equal $sharedTemplate.outputs.frontDoorResourceId.type 'string' 'The shared template must output the profile resource ID.'
Assert-Equal $sharedTemplate.outputs.frontDoorId.type 'string' 'The shared template must expose its FDID GUID.'
foreach ($resource in @($resources.Values) + @($routingResources.Values)) {
    Assert-True ($resource.type -ine 'Microsoft.Cdn/profiles') 'WordPress must never create a Front Door profile, including in its routing module.'
}
Assert-True (-not $resources.ContainsKey('frontDoorDiagnostics')) 'WordPress must not overwrite shared profile diagnostics.'
Assert-Equal $template.parameters.setupFrontDoorRoutes.type 'bool' 'Route setup must use a boolean parameter.'
Assert-Equal $template.parameters.setupFrontDoorRoutes.defaultValue $true 'Route setup must default to enabled.'
Assert-Equal $template.parameters.frontDoorResourceId.type 'string' 'The shared profile reference must be a string.'
Assert-Equal $template.parameters.frontDoorResourceId.defaultValue '' 'The profile reference must be optional when routing is disabled.'
Assert-Equal $resources.frontDoorRoutes.condition "[parameters('setupFrontDoorRoutes')]" 'All site Front Door resources must be behind the routing condition.'
Assert-Equal $resources.frontDoorRoutes.subscriptionId "[variables('frontDoorSubscriptionId')]" 'The routes must deploy in the referenced subscription.'
Assert-Equal $resources.frontDoorRoutes.resourceGroup "[variables('frontDoorResourceGroupName')]" 'The routes must deploy in the referenced resource group.'
Assert-Equal $template.variables.frontDoorSubscriptionId "[if(parameters('setupFrontDoorRoutes'), split(parameters('frontDoorResourceId'), '/')[2], variables('subscriptionId'))]" 'A disabled setup must not parse the profile subscription.'
Assert-Equal $template.variables.frontDoorResourceGroupName "[if(parameters('setupFrontDoorRoutes'), split(parameters('frontDoorResourceId'), '/')[4], variables('resourceGroupName'))]" 'A disabled setup must not parse the profile resource group.'
Assert-Equal $template.variables.frontDoorProfileName "[if(parameters('setupFrontDoorRoutes'), split(parameters('frontDoorResourceId'), '/')[8], 'unused')]" 'A disabled setup must not parse the profile name.'
Assert-Equal $resources.frontDoorRoutes.properties.parameters.siteResourceName.value "[variables('webAppName')]" 'The routing namespace must use the source app identity, not the shared resource group.'
Assert-True ($template.variables.frontDoorEndpointName.Contains("take(variables('sanitizedName'), 29)")) 'Endpoint names must truncate the readable prefix rather than the uniqueness suffix.'
Assert-True ($template.variables.uniqueSuffix.Contains('resourceGroup().id')) 'Different source resource groups must receive different site namespaces.'
Assert-Equal $routingTemplate.variables.frontDoorOriginGroupName "[format('{0}-wordpress', parameters('siteResourceName'))]" 'Website origins must be isolated per site.'
Assert-Equal $routingTemplate.variables.frontDoorBlobOriginGroupName "[format('{0}-media', parameters('siteResourceName'))]" 'Media origins must be isolated per site.'
Assert-True ($routingResources.frontDoorSecurityPolicy.name.Contains("parameters('siteResourceName')")) 'WAF associations must be isolated per site.'
Assert-True ($routingTemplate.variables.frontDoorWafPolicyName.Contains("parameters('siteResourceName')")) 'Each site must own a separate WAF policy.'
Assert-Equal $resources.frontDoorRoutes.properties.parameters.enableFrontDoorCaching.value "[parameters('enableFrontDoorCaching')]" 'The caching switch must reach every site route.'
Assert-Equal $resources.frontDoorRoutes.properties.parameters.enableBlobStorage.value "[parameters('enableBlobStorage')]" 'Blob routing must remain independently optional.'
Assert-Equal $appModule.parameters.setupFrontDoorRoutes.value "[parameters('setupFrontDoorRoutes')]" 'App configuration must receive the routing flag.'
foreach ($parameterName in @('frontDoorId', 'frontDoorEndpointHostName')) {
    Assert-True ($appModule.parameters[$parameterName].StartsWith("[if(parameters('setupFrontDoorRoutes'),") -and $appModule.parameters[$parameterName].EndsWith("createObject('value', ''))]")) "Disabled routing must not read $parameterName from a skipped module."
}
Assert-True ($routingTemplate.outputs.frontDoorId.value.EndsWith('.frontDoorId]')) 'App access must use the profile GUID rather than the ARM resource ID.'
Assert-Equal $webConfiguration.properties.ipSecurityRestrictionsDefaultAction 'Deny' 'Disabling routing must not open public App Service access.'
Assert-Equal $webConfiguration.properties.scmIpSecurityRestrictionsUseMain $true 'SCM must retain the same restrictions as the website.'
$accessRules = $webConfiguration.properties.ipSecurityRestrictions
Assert-True ($accessRules.StartsWith("[if(parameters('setupFrontDoorRoutes'),") -and $accessRules.EndsWith(', createArray())]')) 'The Front Door allow rule must be omitted when routing is disabled.'
Assert-True ($accessRules.Contains('AzureFrontDoor.Backend') -and $accessRules.Contains("'X-Azure-FDID', createArray(parameters('frontDoorId'))")) 'The allow rule must validate both the Front Door service tag and profile GUID.'
Assert-True ($appSettings.Contains("createObject('name', 'AFD_ENABLED', 'value', string(parameters('setupFrontDoorRoutes')))")) 'The container Front Door flag must follow routing setup.'
Assert-True ($appSettings.Contains("if(parameters('setupFrontDoorRoutes'), createArray(createObject('name', 'AFD_ENDPOINT'")) 'The endpoint setting must be absent when routing is disabled.'
Assert-True ($appSettings.Contains("if(and(parameters('setupFrontDoorRoutes'), parameters('enableBlobStorage')), createArray(createObject('name', 'WPAT_BLOB_CDN_HOST'")) 'Media CDN settings must require both Blob storage and routing.'
Assert-True ($template.outputs.frontDoorEndpointHostName.value.StartsWith("[if(parameters('setupFrontDoorRoutes'),")) 'The website Front Door output must be empty when routing is disabled.'

foreach ($scriptName in @('deployDev.ps1', 'deployProd.ps1')) {
    $parseErrors = $null
    $tokens = $null
    $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $bicepDirectory $scriptName), [ref] $tokens, [ref] $parseErrors)
    Assert-Equal $parseErrors.Count 0 "$scriptName must have valid PowerShell syntax."
    $validationFunction = $scriptAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-FrontDoorConfiguration' }, $true)
    if ($scriptName -eq 'deployDev.ps1') {
        Assert-True ($null -eq $scriptAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) 'The dev deployment must remain inline without helper functions.'
        Assert-True ($scriptAst.Extent.Text.Contains('az afd profile show')) 'The dev deployment must look up the existing shared profile.'
        Assert-True ($scriptAst.Extent.Text.Contains('"frontDoorResourceId=$frontDoorResourceId"')) 'The dev deployment must override the parameter file with the resolved full ID.'
        continue
    }
    Assert-True ($null -ne $validationFunction) "$scriptName must validate the shared profile before deployment."
    . ([scriptblock]::Create($validationFunction.Extent.Text))
    foreach ($profileId in @('', 'not-a-resource-id', '/subscriptions/<subscription-id>/resourceGroups/shared/providers/Microsoft.Cdn/profiles/example')) {
        Assert-FrontDoorConfiguration -Parameters @{ setupFrontDoorRoutes = @{ value = $false }; frontDoorResourceId = @{ value = $profileId } }
        $rejected = $false
        try { Assert-FrontDoorConfiguration -Parameters @{ frontDoorResourceId = @{ value = $profileId } } } catch { $rejected = $true }
        Assert-True $rejected "$scriptName must reject an invalid profile reference when route setup defaults to true."
    }
    Assert-FrontDoorConfiguration -Parameters @{ setupFrontDoorRoutes = @{ value = $false } }
    $validId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/shared-frontdoor/providers/Microsoft.Cdn/profiles/shared-afd'
    foreach ($routeParameter in @(@{}, @{ setupFrontDoorRoutes = @{ value = $true } })) {
        $routeParameter.frontDoorResourceId = @{ value = $validId }
        Assert-FrontDoorConfiguration -Parameters $routeParameter
    }
    $rejected = $false
    try { Assert-FrontDoorConfiguration -Parameters @{ setupFrontDoorRoutes = @{ value = 'false' } } } catch { $rejected = $true }
    Assert-True $rejected "$scriptName must reject a string in place of a JSON boolean."
}

foreach ($profileName in @('dev', 'prod')) {
    $profilePath = Join-Path $bicepDirectory "wordpress-deployment-arm-template.$profileName.parameters.sample.json"
    $sampleProfile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json -AsHashtable
    Assert-Equal $sampleProfile.parameters.enableBlobStorage.value $false "The $profileName sample must require an explicit Blob opt-in."
    Assert-Equal $sampleProfile.parameters.enableRedis.value $false "The $profileName sample must leave Redis disabled."
    Assert-Equal $sampleProfile.parameters.setupFrontDoorRoutes.value $true "The $profileName sample must enable site routes by default."
    Assert-Equal $sampleProfile.parameters.enableFrontDoorCaching.value $true "The $profileName sample must enable caching by default."
    Assert-True ($sampleProfile.parameters.frontDoorResourceId.value.Contains('/providers/Microsoft.Cdn/profiles/')) "The $profileName sample must show a full shared profile reference."
    foreach ($parameterName in $sampleProfile.parameters.Keys) {
        Assert-True ($template.parameters.ContainsKey($parameterName)) "The $profileName sample parameter $parameterName must exist in the template."
    }
    $sharedProfile = Get-Content -LiteralPath (Join-Path $bicepDirectory "frontdoor-deployment.$profileName.parameters.sample.json") -Raw | ConvertFrom-Json -AsHashtable
    foreach ($parameterName in $sharedProfile.parameters.Keys) {
        Assert-True ($sharedTemplate.parameters.ContainsKey($parameterName)) "The shared $profileName sample parameter $parameterName must exist in the standalone template."
    }
}

foreach ($profilePath in Get-ChildItem -LiteralPath $bicepDirectory -Filter 'wordpress-deployment-arm-template.*.parameters.json') {
    $actualProfile = Get-Content -LiteralPath $profilePath.FullName -Raw | ConvertFrom-Json -AsHashtable
    foreach ($parameterName in @('setupFrontDoorRoutes', 'frontDoorResourceId', 'enableFrontDoorCaching')) {
        Assert-True ($actualProfile.parameters.ContainsKey($parameterName)) "The local $($profilePath.Name) profile must contain $parameterName."
    }
    foreach ($parameterName in $actualProfile.parameters.Keys) {
        Assert-True ($template.parameters.ContainsKey($parameterName)) "The local $($profilePath.Name) parameter $parameterName must exist in the template."
    }
}

Write-Output "PASS: $($assertions.Count) compiled-template and sample-profile assertions; no Azure resources were queried or changed."