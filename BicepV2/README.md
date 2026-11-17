# Azure WordPress Bicep V2 Deployment

This template deploys a WordPress container to Azure App Service with Azure Database for MySQL Flexible Server, a virtual network, private DNS, and a user-assigned managed identity. Front Door is a separately deployed shared profile: the WordPress template optionally configures this site's endpoints and routes on that existing profile. Redis, Blob media storage, and Azure Communication Services email are independently optional and disabled by default.

## Deployment layout

| File | Responsibility |
| --- | --- |
| [frontdoor-deployment.bicep](frontdoor-deployment.bicep) | Deploy the shared Front Door Standard profile once, with diagnostics sent to an existing or automatically created Log Analytics workspace. This is the only template that creates the profile. |
| [frontdoor-deployment.dev.parameters.sample.json](frontdoor-deployment.dev.parameters.sample.json) | Example shared profile settings for development. |
| [frontdoor-deployment.prod.parameters.sample.json](frontdoor-deployment.prod.parameters.sample.json) | Example shared profile settings for production. |
| [wordpress-deployment-arm-template.bicep](wordpress-deployment-arm-template.bicep) | Deploy one WordPress environment and optionally configure it on the existing shared profile. |
| [modules/frontdoor-routes.bicep](modules/frontdoor-routes.bicep) | Configure this site's endpoints, origins, routes, WAF policy, and security association. References the profile; never creates it. |

### Recommended workflow

1. Prepare a local WordPress parameter file from the dev or prod sample and replace password placeholders. Keep secret-bearing parameter files out of source control.
2. Deploy the shared Front Door template into a separate resource group, or reuse an existing Standard profile. See [Shared Front Door](#shared-front-door) for commands.
3. Set `frontDoorResourceId.value` in the WordPress parameter file to the shared deployment's `frontDoorResourceId` output for manual/prod deployment. For [deployDev.ps1](deployDev.ps1), set `$frontDoorResourceGroupName` and `$frontDoorProfileName` instead; it looks up the full ID in the current Azure CLI subscription and overrides the file value. Keep `setupFrontDoorRoutes=true` to configure the site's ingress.
4. Build both templates and run the offline regression checks in [Validate](#validate), then run Azure validation/what-if before deployment.
5. Deploy the WordPress template to its own resource group and initialize WordPress through its website Front Door endpoint. For Blob media, complete the [post-deployment configuration](#configure-w3-total-cache-after-deployment) separately.

**The example deployment scripts delete the app resource group and purge Key Vault at the end.** Use the manual deployment commands below for an environment you intend to keep, or remove that teardown before using the scripts. Do not place the shared profile in the app resource group.

## Prerequisites

- Azure CLI 2.56 or later, authenticated with `az login`.
- The Azure CLI Bicep integration installed with `az bicep install` or updated with `az bicep upgrade`.
- Permission to create the listed Azure resources in the target resource group.
- `Owner` or `User Access Administrator` permission at the target scope. The template creates role assignments for the managed identity.

Verify the selected container image before deployment. During local validation on 2026-10-30, the existing `mcr.microsoft.com/appsvc/wordpress-debian-php:8.4` tag returned `manifest unknown`. The template and samples have not silently substituted a different image. Select and validate a supported App Service WordPress image, including its managed-identity bootstrap, before rollout.

## Environment profiles

Use one committed, non-secret profile per environment:

| Environment | App Service plan | MySQL HA | Redis | Storage | Soft delete | WAF |
| --- | --- | --- | --- | --- | --- | --- |
| `dev` | P0V3, 1 instance, no zone redundancy | Disabled, Burstable | Not deployed; HA disabled if opted in | LRS | 7 days | Detection |
| `test` | P1V3, 2 instances, no zone redundancy | SameZone, General Purpose | Opt-in; HA recommended | ZRS | 14 days | Detection |
| `prod` | P1V3, 3 instances, zone redundant | ZoneRedundant, General Purpose | Not deployed; HA enabled if opted in | RA-GRS | 30 days | Prevention |

Only `dev` and `prod` ship as sample profiles: [wordpress-deployment-arm-template.dev.parameters.sample.json](wordpress-deployment-arm-template.dev.parameters.sample.json) and [wordpress-deployment-arm-template.prod.parameters.sample.json](wordpress-deployment-arm-template.prod.parameters.sample.json). Copy the one closest to your target environment to a git-ignored `*.parameters.json` file, set `environmentName` accordingly (`dev`, `test`, or `prod`), and fill in the real values. The samples contain password placeholders but no real passwords, Redis keys, or other secrets.

`environmentName` is restricted to `dev`, `test`, or `prod` and is applied as the `Environment` tag. App Service zone redundancy (`appServiceZoneRedundant`) and MySQL HA (`mysqlHighAvailabilityMode`) are independent. Network prefixes, Blob/container soft-delete retention, previous-version retention, Front Door probe path/interval, and WAF mode are explicit profile parameters.

When enabled, the media account allows public networking and anonymous Blob reads, and has the tag `securitycontrol=ignore`. Its container permits individual-blob reads, not anonymous listing or writes. The tag is metadata, not an automatic Azure Policy exemption. `enableBlobStorage` controls Blob infrastructure, WordPress integration, and the website's uploads route; it does not select a private-storage mode. Storage SKUs and retention settings in the profiles apply only when Blob storage is enabled. Key Vault and MySQL remain private; Redis is private when enabled.

## Required parameters

The main template is `wordpress-deployment-arm-template.bicep`.

| Parameter | Description |
| --- | --- |
| `name` | Prefix for deployed resources and the App Service site name. Use lowercase letters, numbers, and hyphens. |
| `environmentName` | Deployment environment: `dev`, `test`, or `prod`. |
| `wordpressAdminEmail` | WordPress administrator account email, required even when outbound email is disabled. |
| `wordpressPassword` | Secure WordPress administrator password. |
| `serverPassword` | Secure MySQL administrator password. |

The WordPress deployment creates a Log Analytics workspace and workspace-based Application Insights component. Its diagnostic settings use that workspace automatically, and the App Service receives the Application Insights connection string automatically. Shared Front Door diagnostics are configured separately, as described below.

## Shared Front Door

| Parameter | Default | Description |
| --- | --- | --- |
| `setupFrontDoorRoutes` | `true` | Configure this site's endpoints, origins, routes, WAF policy, and WAF associations on an existing shared profile. Never creates a Front Door profile. |
| `frontDoorResourceId` | Empty string | Full ARM resource ID of an existing Standard Azure Front Door profile; required when route setup is enabled and ignored completely when disabled. The empty default is not sufficient with the default `setupFrontDoorRoutes=true`. |
| `enableFrontDoorCaching` | `true` | Enable query-string-aware caching on the WordPress, dedicated Blob, and website uploads routes. Set `false` to disable caching on all three. |

The values below belong inside the `parameters` object of a WordPress parameter file:

```json
"setupFrontDoorRoutes": { "value": true },
"frontDoorResourceId": {
  "value": "/subscriptions/<subscription-id>/resourceGroups/<shared-resource-group>/providers/Microsoft.Cdn/profiles/<profile-name>"
},
"enableFrontDoorCaching": { "value": true }
```

| Route setup | Blob storage | Result |
| --- | --- | --- |
| Enabled | Disabled | Website endpoint with only the main `/*` route to App Service, including uploads; no `wordpress-media` route or dedicated Blob endpoint; site-specific WAF protection. |
| Enabled | Enabled | Website endpoint plus dedicated Blob endpoint; website uploads route points to Blob; site-specific WAF protection on both endpoints. |
| Disabled | Either | No Front Door/WAF deployment or profile lookup; Front Door outputs are empty. App Service/SCM remain publicly blocked. Blob infrastructure follows its own switch. |

Deploy [frontdoor-deployment.bicep](frontdoor-deployment.bicep) once into a separate shared resource group. It owns the Front Door Standard profile and always configures its diagnostic setting to send all logs and metrics to Log Analytics. Supply `logAnalyticsWorkspaceResourceId` to reuse an existing workspace. When omitted or empty, the template creates a deterministically named workspace in the shared resource group's region, using the supplied tags, the `PerGB2018` pay-as-you-go SKU, and 30-day retention. The `diagnosticsWorkspaceResourceId` output identifies the selected workspace. The dev/prod standalone sample files leave the ID empty, so they create a workspace by default; ingestion and retention charges apply. The template does not create WordPress infrastructure, endpoints, routes, or WAF policies, and has no dependency on a WordPress deployment.

From this directory, provision the shared profile before deploying WordPress:

```powershell
az group create --name 'shared-frontdoor-dev-rg' --location 'southafricanorth'
az deployment group create `
  --resource-group 'shared-frontdoor-dev-rg' `
  --name 'shared-frontdoor' `
  --template-file './frontdoor-deployment.bicep' `
  --parameters '@frontdoor-deployment.dev.parameters.sample.json'

$frontDoorResourceId = az deployment group show `
  --resource-group 'shared-frontdoor-dev-rg' `
  --name 'shared-frontdoor' `
  --query properties.outputs.frontDoorResourceId.value --output tsv
```

For manual deployment or [deployProd.ps1](deployProd.ps1), set `frontDoorResourceId.value` in your local WordPress parameter file to that output. Its format is `/subscriptions/<subscription-id>/resourceGroups/<shared-resource-group>/providers/Microsoft.Cdn/profiles/<profile-name>`. The profiles contain a placeholder; replace it for these deployment paths. [deployDev.ps1](deployDev.ps1) instead resolves the ID with `az afd profile show` using its inline `$frontDoorResourceGroupName` and `$frontDoorProfileName` settings, stores it in `$frontDoorResourceId`, and passes it as an override without modifying the JSON file. The lookup is skipped when route setup is disabled and stops the script if it fails. The value is an ARM resource ID, not an endpoint URL or the profile's FDID GUID.

Then deploy the WordPress template to the app resource group, with the local password values already configured:

```powershell
az group create --name 'wordpress-dev-rg' --location 'southafricanorth'
az deployment group create `
  --resource-group 'wordpress-dev-rg' `
  --name 'wordpress-dev' `
  --template-file './wordpress-deployment-arm-template.bicep' `
  --parameters '@wordpress-deployment-arm-template.dev.parameters.json'
```

The conditional [routing module](modules/frontdoor-routes.bicep) deploys into the profile's subscription/resource group, which may differ from the WordPress resource group. The deployment identity needs deployment and resource-write permissions in that shared scope as well as permissions for the app deployment. The profile must already exist and use `Standard_AzureFrontDoor`. It is only referenced with `existing`; an empty reference never triggers local profile creation.

Each WordPress deployment owns separate website/media endpoints, origin groups, origins, routes, WAF policy, and security association within the shared resource group. Names incorporate the source app identity and its resource-group-specific suffix. Different sites therefore retain their own `/*` route without overwriting each other's origins or WAF associations. The shared profile's FDID GUID is passed to the App Service access rule automatically. Shared diagnostics are never overwritten by a WordPress deployment.

When `setupFrontDoorRoutes=false`, no Front Door or WAF resources are created or queried, and the reference can be empty or malformed. The container gets `AFD_ENABLED=false`; `AFD_ENDPOINT` and `WPAT_BLOB_CDN_HOST` are omitted, and all Front Door outputs are empty strings. **App Service and SCM remain deny-by-default with no public allow rule**, so this mode deploys infrastructure without a public ingress path. It does not grant direct access to the App Service hostname. Blob storage can still be provisioned independently, including its existing public media-read policy; the CDN configuration helper needs a separately configured ingress before use.

To deploy without Front Door integration, use:

```json
"setupFrontDoorRoutes": { "value": false },
"frontDoorResourceId": { "value": "" }
```

This setting skips route configuration; it is not a request to create a different Front Door or automatically delete existing routes.

Caching remains enabled by default on all three routes when routing is enabled. Responses must have appropriate origin cache-control headers, especially authenticated/admin responses; review those before enabling production traffic. Blob compression settings are preserved when caching is enabled.

### Lifecycle and migration

Use separate app and shared resource groups. The example app deployment scripts still delete the app resource group and purge Key Vault at the end; they do not manage shared Front Door provisioning or cleanup. Do not run them for a persistent environment without removing that teardown. App-specific Front Door children and the site's WAF policy live in the shared resource group and outlive app resource-group deletion. Before retiring an app, stop traffic and remove only its security association, endpoints/routes, origin groups/origins, and WAF policy, then retire its app resources. Preserve the shared profile, diagnostics, and other sites' resources.

An incremental deployment does not delete resources removed from a template or disabled by a condition. Setting `setupFrontDoorRoutes=false` stops managing this site's Front Door resources; it does not remove existing public endpoints, routes, or WAF associations. Decommission them explicitly after reviewing dependencies. Likewise, extracting the profile declaration does not move or delete an old app-owned Front Door. Moving an existing site to a different profile requires a planned endpoint/domain and WordPress URL cutover; do not delete the old app resource group until that migration is verified. Complete deployment mode is not a cleanup shortcut.

## Optional email

| Parameter | Default | Description |
| --- | --- | --- |
| `enableEmail` | `false` | Opt in to Azure Communication Services email and its WordPress app settings. Both sample profiles explicitly set this to `false`. |
| `emailDataLocation` | `unitedstates` | Communication Services data geography; ignored unless `enableEmail` is `true`. |

To enable outbound email, set `"enableEmail": { "value": true }` in your deployment parameter file and select a supported `emailDataLocation`.

When email is disabled, the template skips the Email Communication Service, Azure-managed domain, Communication Service, custom email role, role assignment, and Communication Services diagnostic setting. It omits `WP_EMAIL_CONNECTION_STRING` and `ENABLE_EMAIL_MANAGED_IDENTITY` entirely from App Service settings. `WORDPRESS_ADMIN_EMAIL` remains configured for the administrator account.

When email is enabled, the template creates those resources and includes both email app settings using the managed domain and managed identity. The existing custom role's send permissions still require validation; verify a test email before relying on delivery.

Disabling email on an existing deployment removes the template-managed email app settings, but an incremental deployment does not delete previously created email resources, role assignments, or diagnostic settings. Review and decommission those separately when retiring email.

## Optional Redis

| Parameter | Default | Description |
| --- | --- | --- |
| `enableRedis` | `false` | Deploy Azure Managed Redis, its database, key secret, private endpoint/DNS resources, diagnostics, and WordPress Redis settings. |
| `redisSkuName` | `Balanced_B0` | Used only when Redis is enabled. |
| `redisHighAvailabilityEnabled` | `true` | Used only when Redis is enabled; the dev sample selects `false`. |

Both sample profiles explicitly set `enableRedis=false`. No `REDIS_*` or `WP_REDIS_*` settings are emitted when disabled, and the `redisDatabaseHostName` output is empty. To opt in, set `"enableRedis": { "value": true }` in your parameter file. Configure and verify the chosen WordPress object-cache plugin separately; Blob CDN delivery does not require Redis.

Turning Redis off removes template-managed Redis app settings. An incremental deployment does **not** delete existing Redis resources, secrets, private endpoints, DNS zones, or diagnostic settings. Disable any plugin configuration that still uses Redis and decommission those resources separately after review.

## Validate

From this directory, build the complete module tree:

```powershell
az bicep build --file wordpress-deployment-arm-template.bicep
az bicep build --file frontdoor-deployment.bicep
```

Run the deployment-free Blob configuration regression check from the repository root:

```powershell
.\BicepV2\tests\Test-BlobStorageConfiguration.ps1
```

It compiles both templates and checks shared-profile ownership, conditional cross-resource-group routing, guarded profile references and outputs, deny-by-default access, deployment-script preflight behavior, caching on all routes, Blob/Redis/email opt-in, public Blob access and its tag, keyless access, retention, and parameter profiles. It does not query or change Azure resources, or execute the deployment scripts. These are compiled-template and offline preflight checks, not a live Azure deployment test.

[deployDev.ps1](deployDev.ps1) and [deployProd.ps1](deployProd.ps1) are example end-to-end deployment scripts. Each hardcodes its own `$resourceGroupName`, `$parameterFileName`, and `$location` at the top of the file; edit those values (or copy the script) before running:

```powershell
.\deployDev.ps1
```

When route setup is enabled, the dev script looks up the existing shared profile; the prod script validates the reference supplied in its parameter file. Neither script creates the shared profile or runs Azure `validate` or `what-if` first. Both then create the app resource group and run `az deployment group create` directly. For production or unattended changes, run `az deployment group validate` and `az deployment group what-if` yourself against the template and effective parameters before deploying, especially to check SKU availability, quota, zone redundancy, shared-scope permissions, and any resource replacements.

Both example scripts also **delete the resource group and purge its Key Vault** at the end of the run, which is only appropriate for disposable test cycles. Remove those final `az group delete` / `az keyvault purge` lines from your own copy before using it against an environment you intend to keep.

Do not commit deployment parameter files containing real passwords or other secrets. Use a local, ignored copy for values that must remain confidential.

Use a short, globally unique `<site-name>` such as `contoso-wp-dev`. The template appends a deterministic suffix to resource names where Azure requires uniqueness.

## Use after deployment

This section assumes `setupFrontDoorRoutes=true`. With route setup disabled, there is no template-configured public ingress and the Front Door hostname outputs are empty.

Get the Azure Front Door hostname from the completed deployment and use it to finish the WordPress setup. Do not initialize WordPress through the App Service default hostname because WordPress can persist that origin as its canonical URL.

```powershell
az deployment group show `
  --resource-group '<resource-group-name>' `
  --name '<deployment-name>' `
  --query properties.outputs.frontDoorEndpointHostName.value `
  --output tsv
```

Open `https://<front-door-hostname>/`. The App Service receives `AFD_ENABLED=true` and the hostname-only `AFD_ENDPOINT` setting required by the Microsoft WordPress image. After a deployment or configuration change, restart the Web App and allow up to approximately 15 minutes for the image to apply the Front Door URL to WordPress.

For an existing site that still generates `azurewebsites.net` URLs, redeploy this template, restart the Web App, wait for configuration to converge, and then verify the home page, posts, categories, author pages, admin login, canonical links, redirects, and asset URLs through Front Door. Keep both AFD settings in place after convergence.

If URLs still point to the origin after that process, back up the database and inspect `wp-config.php` plus `wp option get home` and `wp option get siteurl` through the App Service SSH/Kudu environment. Use WP-CLI option updates or search-replace for the exact old and new URLs if repair is required. Do not use blind SQL because WordPress content can contain serialized values.

The MySQL server is configured for private VNet access and MySQL 8.4. Access occurs from App Service through VNet integration and managed identity configuration. Key Vault has a private endpoint and private DNS zone; Blob Storage and Redis get their own only when enabled. The Web App itself deliberately has no private endpoint. Enabled Blob Storage also has public access for media reads.

When route setup is enabled, Azure Front Door Standard with a site-specific WAF policy is the public entry point. The App Service accepts requests only from the `AzureFrontDoor.Backend` service tag containing the shared profile's specific `X-Azure-FDID` header. Direct access to the App Service hostname should return `403`.

## Optional Blob media

This option follows Microsoft's [WordPress Blob Storage guide](https://github.com/Azure/wordpress-linux-appservice/blob/main/WordPress/wordpress_azure_blob_storage.md) and [Front Door integration guide](https://github.com/Azure/wordpress-linux-appservice/blob/main/WordPress/wordpress_afd_configuration.md): W3 Total Cache uploads media to Blob Storage, which serves it over public, read-only HTTPS URLs. No custom media-delivery plugin is required.

| Parameter | Default | Description |
| --- | --- | --- |
| `enableBlobStorage` | `false` | Deploy Blob media infrastructure, enable WordPress media offload, and create the website's Blob uploads route when Front Door route setup is enabled. Both sample profiles leave it disabled, so new deployments create no Blob storage or related resources. |

Set this entry in the `parameters` object of your deployment parameter file to opt in:

```json
"enableBlobStorage": { "value": true }
```

Provisioned only when `enableBlobStorage=true` (Front Door resources additionally require `setupFrontDoorRoutes=true`):

- The storage account has `securitycontrol=ignore`, public networking, and `allowBlobPublicAccess=true`. The media container uses `publicAccess: 'Blob'`: individual blobs are publicly readable, but anonymous container listing and writes are not allowed.
- A dedicated Front Door media endpoint forwards `/<container>/wp-content/uploads/*` to the Blob origin with the same path. This matches the URL generated by W3 Total Cache's Azure managed-identity engine. No extra container prefix is added. HTTP redirects to HTTPS, origin certificate checks remain enabled, and query strings are included in media cache keys. `enableFrontDoorCaching` controls caching on this route and both website routes.
- Both the website and media endpoints have the deployment's WAF association. Their respective outputs are `frontDoorEndpointHostName` and `frontDoorBlobEndpointHostName`; `frontDoorBlobMediaBaseUrl` includes the container/uploads path.
- The Blob private endpoint, private DNS zone, VNet link, and DNS zone group provide App Service access. Keep the normal `<account>.blob.core.windows.net` hostname, not a `privatelink` hostname.
- The Blob service, media container, version-retention policy, managed-identity Blob Data Contributor role assignment, and Blob diagnostics are deployed with the storage account.

When WordPress Blob integration is enabled, App Service receives `BLOB_STORAGE_ENABLED=true`, `STORAGE_ACCOUNT_NAME`, `BLOB_CONTAINER_NAME`, `BLOB_STORAGE_URL`, and `ENABLE_BLOB_MANAGED_IDENTITY=true`. With route setup also enabled, it receives `WPAT_BLOB_CDN_HOST`. The last setting is a toolkit-specific hostname consumed by the configuration helper; do not assume the stock image consumes it. Keep `BLOB_STORAGE_URL` pointed at the storage account for authenticated operations, not at Front Door. The existing managed identity and Blob Data Contributor role handle uploads; Shared Key stays disabled and no storage key is injected.

When route setup is enabled, the website's `/wp-content/uploads/*` route also forwards to `/<container>/wp-content/uploads/*` on Blob when Blob integration is enabled. Other website paths continue to use App Service. This route keeps existing same-site media URLs working, while W3 Total Cache can emit the dedicated media endpoint's container-prefixed URLs.

**All blobs in this container must be suitable for public access.** Do not put backups, credentials, or restricted/member-only media there. Direct Blob URLs bypass Front Door and its WAF. Public reads do not grant permission to upload, change, or delete blobs.

When Blob integration is disabled, `BLOB_STORAGE_ENABLED=false`; the five Blob-specific settings above are omitted, and new sites keep media on the persistent App Service filesystem. No storage account, Blob service/container/retention policy, Blob role assignment, Blob private networking, Blob diagnostics, dedicated Blob Front Door endpoint/origin group/origin/route, or website `wordpress-media` route is created. If route setup is enabled, the website's main `/*` route handles uploads through App Service, and the WAF association includes only the website endpoint. `storageAccountNameOutput`, `frontDoorBlobEndpointHostName`, and `frontDoorBlobMediaBaseUrl` are empty strings. The shared `ENTRA_CLIENT_ID` remains because MySQL also uses it.

An incremental redeployment does **not** delete previously created Blob resources or the `wordpress-media` route. Before disabling Blob on an existing site, migrate media back to App Service and explicitly remove the old `wordpress-media` route so the main `/*` route can handle uploads; otherwise the retained route can still send uploads requests to Blob. Existing blobs and the dedicated media endpoint may remain publicly accessible, and that endpoint is no longer included in the template-managed WAF association when disabled. Review and decommission retained resources separately after backing up or migrating media; disabling this option does not make existing media private. Do not switch to complete deployment mode as a cleanup shortcut.

### Existing sites

Microsoft documents these Blob settings as [one-time initialization settings](https://github.com/Azure/wordpress-linux-appservice/blob/main/WordPress/wordpress_application_settings.md). Changing the parameter and restarting an existing site does not automatically migrate files or reconfigure saved W3 Total Cache settings.

- Before enabling on an existing site, back up, synchronize existing uploads and thumbnails, and configure W3 Total Cache's CDN integration for the target container and Front Door hostname. Keep its scope to media under `wp-content/uploads`, not themes, scripts, or `wp-includes`. The enabled Front Door uploads route has no local-file fallback, so complete the media migration before switching traffic.
- Do not run the private-media installer's normal setup for public delivery; it disables W3 Total Cache's CDN feature. If the earlier proxy was activated, disable it with `wp option update wpat_private_media_enabled 0` during the cutover. Its archive commands can remain installed for backup/restore without enabling its delivery mode.
- Before disabling, restore any Blob-only media to local `wp-content/uploads`, disable W3 Total Cache's CDN feature, and repair saved media URLs where needed. Then redeploy with `enableBlobStorage=false`, which routes website uploads to App Service and skips Blob infrastructure. Incremental deployment retains previously created Blob resources; review and decommission those separately. Purge W3 Total Cache page caches and Front Door caches separately, especially when replacing a file at the same URL.

The earlier [private-media helper](../HelperScript/README.md#private-blob-media) remains available for explicitly configured private-proxy installations, but it is not selected or configured by this simple boolean option.

WordPress posts, pages, settings, and attachment metadata remain in MySQL. Themes, plugins, and configuration remain on the persistent App Service filesystem. Blob Storage contains uploaded media; it is not a mount for the whole WordPress installation.

### Configure W3 Total Cache after deployment

Use [Configure-WordPressBlobStorage.ps1](../HelperScriptv2/Configure-WordPressBlobStorage.ps1) after WordPress initialization, particularly for an existing site. Bicep provisions infrastructure and app settings; it does not edit existing W3 Total Cache configuration. The helper is an explicit post-deployment step, not an automatic deployment action.

For an existing site, take a full backup and isolate traffic/background writers **before** deploying with `enableBlobStorage=true`: that deployment switches the website's uploads route before the helper copies files. Keep traffic isolated until verification succeeds. Install a reviewed W3 Total Cache version with the `azuremi` engine; Redis is not needed for this CDN mode.

From the repository root:

```powershell
.\HelperScriptv2\Configure-WordPressBlobStorage.ps1 `
  -ResourceGroup 'my-wordpress-rg' -AppName 'my-wordpress-app' `
  -SyncUploads -Quiesced
```

The command reads the target account, container, managed identity, and `WPAT_BLOB_CDN_HOST` from the app. It tests a temporary object's anonymous HTTPS reads through Blob and Front Door, backs up current configuration outside the web root, uploads existing local media, and configures W3 Total Cache's `azuremi` engine and media-only CDN hostname. Local copies remain. **`-SyncUploads` overwrites matching blobs with local bytes**; use it only when local uploads are authoritative. For media already verified in the target container, use `-MediaAlreadySynced` instead.

Use `-CdnHost 'media.example.com'` only for an already provisioned, TLS-enabled Front Door custom domain with the same container-prefixed route. Use `-WhatIf` for a connection-free preview. The helper requires the v2 PowerShell/SSH prerequisites and approved SCM connectivity; it does not loosen SCM restrictions or change Azure resources. It preserves non-CDN cache settings, database credentials, and maintenance state. It neither migrates old account URLs nor purges edge/page caches. Purge those caches, test a new upload and its thumbnails, and verify public media externally before resuming traffic.

See the [v2 runbook](../HelperScriptv2/readme.md#configure-blob-without-a-restore) for prerequisites, retry/recovery details, and configuration-only versus full migration usage. The v2 migration finalizer also honors `WPAT_BLOB_CDN_HOST`, so a restored site uses the same dedicated endpoint.

### Recovery and retention

Blob versioning is enabled. `blobVersionRetentionDays` defaults to `90` (allowed range `1` to `3650`); the dev sample uses `30`, and prod uses `90`. The lifecycle rule is limited to the media container and deletes **previous versions only**, never current blobs. Existing Blob/container soft-delete retention remains independent. Versioning increases storage consumption; monitor it alongside retained local copies.

Versioning, soft delete, and RA-GRS are not independent backups. Point-in-time restore and change feed remain disabled. Full helper backups require the media archive commands when Blob integration is configured; install the helper with `-InstallOnly` for archive commands without enabling private-proxy delivery. Matching restores import media into the target environment's configured container. Back up to a separately secured destination, quiesce writes for consistency, and test recovery before relying on an RPO/RTO. See the [helper runbook](../HelperScript/README.md) for details.

Before production, verify the selected image's W3 Total Cache managed-identity support, an upload and its thumbnails, anonymous HTTPS reads through Blob and Front Door, denied anonymous writes/listing, and backup/restore. Local Bicep checks do not prove that the image's one-time bootstrap has configured a deployed site. The production MCR image could not be tested because the configured tag was unavailable during the earlier validation.

When Redis is enabled, the template provides the plugin password through the `REDIS_PASSWORD` and `WP_REDIS_PASSWORD` Key Vault references; confirm the selected WordPress plugin uses one of those settings or map them in its configuration.

## Modules

The root template composes focused modules from the `modules/` directory:

- `modules/app-service-resources.bicep`
- `modules/frontdoor-routes.bicep`
- `modules/server-parameters-aad-auth-only.bicep`
- `modules/storage-resources.bicep`
- `modules/storage-role-assignment-managed-identity.bicep`
- `modules/subnet-resources.bicep`
- `modules/add-admins.bicep`

## Notes

The root template builds without Bicep diagnostics. Review the resource SKU, public-access, retention, and backup defaults before using it in production.