
# STEP 1 - set the variables
$ResourceGroup = '<your-resource-group>' # From deployDev.ps1; confirm it exists.
$AFDResourceGroup='shared-frontdoor-rg'
$TargetSQLZipFile = "/home/wordpress.sql.zip"
$RemoteSQLCleanFile = "/home/wordpress.sql"
$LocalSQLCleanFile = "wordpress.sql"
$LocalSQLZipFile = "wordpress.sql.zip"
$WPZipFile="wpcontent.zip"
$TargetWPZipFile = "/home/wpcontent.zip"
$WDMZipFile="dwm.zip"
$TargetWDMZipFile="/home/dwm.zip"

$CUSTOMDOMAINURL="ahmsdemo6.ahmedsdemo.com" # Replace with your actual custom domain URL

# STEP 2 - extract relevant values from the environment

$SubscriptionId = az account show --query id -o tsv



# get a list of web apps in the resource group. store it in a variable for later use.
$WebApps = az webapp list --resource-group $ResourceGroup --query '[].{name:name,state:state}' --output json | ConvertFrom-Json
$WebApps | Format-Table -Property name,state
# store just the first name in $FirstWebAppName
$FirstWebAppName = $WebApps[0].name
$AppName = $FirstWebAppName


# Discover Front Door routes by their origins instead of deployment history.
$AppHost = az webapp show --resource-group $ResourceGroup --name $AppName `
    --query defaultHostName --output tsv



$Profiles = az afd profile list --resource-group $AFDResourceGroup `
    --query "[?sku.name=='Standard_AzureFrontDoor' || sku.name=='Premium_AzureFrontDoor']" `
    --output json | ConvertFrom-Json
Write-Host "Discovered Front Door profiles: $(($Profiles | ForEach-Object { $_.name }) -join ', ')"

$FrontDoorProfileName = $Profiles[0].name
$SiteHostName = ([uri]$SiteUrl).DnsSafeHost

$WebsiteEndpointName = az afd endpoint list `
    --resource-group $AFDResourceGroup `
    --profile-name $FrontDoorProfileName `
    --query "[?hostName=='$SiteHostName'].name | [0]" -o tsv

Write-Host "Website Endpoint Name: $WebsiteEndpointName"

$DiscoveredRoutes = @(foreach ($var_profile in $Profiles) {
    $Endpoints = az afd endpoint list --resource-group $AFDResourceGroup `
        --profile-name $var_profile.name --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Could not list Front Door endpoints.' }
    foreach ($Endpoint in $Endpoints) {
        $Routes = az afd route list --resource-group $AFDResourceGroup `
            --profile-name $var_profile.name --endpoint-name $Endpoint.name `
            --output json | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw 'Could not list Front Door routes.' }
        foreach ($Route in $Routes) {
            $OriginGroupName = ($Route.originGroup.id -split '/')[-1]
            $Origins = az afd origin list --resource-group $AFDResourceGroup `
                --profile-name $var_profile.name --origin-group-name $OriginGroupName `
                --output json | ConvertFrom-Json
            if ($LASTEXITCODE -ne 0) { throw 'Could not list Front Door origins.' }
            foreach ($Origin in $Origins) {
                [pscustomobject]@{
                    ProfileName = $var_profile.name
                    HostName = $Endpoint.hostName
                    OriginHost = $Origin.hostName
                    Patterns = $Route.patternsToMatch
                }
            }
        }
    }
})

Write-Host $DiscoveredRoutes
# print out all discovered routes for debugging
Write-Host "Discovered routes:"
$DiscoveredRoutes | ForEach-Object {
    Write-Host "Profile: $($_.ProfileName), Host: $($_.HostName), Origin: $($_.OriginHost), Patterns: $($_.Patterns -join ', ')"
}

$WebsiteRoutes = @($DiscoveredRoutes | Where-Object OriginHost -EQ $AppHost)
$WebsiteHosts = @($WebsiteRoutes.HostName | Sort-Object -Unique)
if ($WebsiteHosts.Count -ne 1) { throw 'Expected exactly one Front Door hostname for this app.' }
$WebsiteHost = $WebsiteHosts[0]
Write-Host "Website host: $WebsiteHost"
# Restrict media discovery to profiles serving this app; do not select arbitrary storage.
$MediaRoutes = @($DiscoveredRoutes | Where-Object {
    $_.ProfileName -in $WebsiteRoutes.ProfileName -and
    $_.OriginHost -match '^[^.]+\.blob\.'
})
$MediaHosts = @($MediaRoutes.HostName | Sort-Object -Unique)

$StorageAccounts = @($MediaRoutes | ForEach-Object { ($_.OriginHost -split '\.')[0] } | Sort-Object -Unique)
if ($MediaHosts.Count -ne 1 -or $StorageAccounts.Count -ne 1) {
    throw 'Could not uniquely identify the media endpoint and storage account.'
}
Write-Host "Media hosts: $($MediaHosts -join ', ')"
Write-Host "Storage accounts: $($StorageAccounts -join ', ')"

$MediaHost = $MediaHosts[0]
$StorageAccount = $StorageAccounts[0]
$MediaPrefixes = @($MediaRoutes | ForEach-Object {
    foreach ($Pattern in $_.Patterns) {
        if (-not $Pattern.EndsWith('/*')) { throw 'Cannot infer a media base URL from this route pattern.' }
        $Pattern.Substring(0, $Pattern.Length - 2)
    }
} | Sort-Object -Unique)
if ($MediaPrefixes.Count -ne 1) { throw 'Could not uniquely identify the media URL path.' }
$MediaBaseUrl = "https://$MediaHost$($MediaPrefixes[0])"
$SiteUrl = "https://$WebsiteHost"
[pscustomobject]@{
    SiteUrl = $SiteUrl
    MediaHost = $MediaHost
    MediaBaseUrl = $MediaBaseUrl
    StorageAccount = $StorageAccount
}

$DatabaseSettingsJson = az webapp config appsettings list `
    --resource-group $ResourceGroup --name $AppName `
    --subscription $SubscriptionId `
    --query "[?name=='DATABASE_HOST' || name=='DATABASE_USERNAME'].{name:name,value:value}" `
    --output json


$DatabaseSettings = $DatabaseSettingsJson | ConvertFrom-Json
$DATABASE_HOST = ($DatabaseSettings | Where-Object name -EQ 'DATABASE_HOST').value
$DATABASE_USERNAME = ($DatabaseSettings | Where-Object name -EQ 'DATABASE_USERNAME').value


$DatabaseSettingsJson = az webapp config appsettings list `
    --resource-group $ResourceGroup --name $AppName `
    --subscription $SubscriptionId `
    --query "[?name=='DATABASE_HOST' || name=='DATABASE_USERNAME'].{name:name,value:value}" `
    --output json

$StorageSettingsJson = az webapp config appsettings list `
    --resource-group $ResourceGroup --name $AppName `
    --subscription $SubscriptionId `
    --query "[?name=='BLOB_CONTAINER_NAME' || name=='BLOB_STORAGE_URL'].{name:name,value:value}" `
    --output json

$StorageSettings = $StorageSettingsJson | ConvertFrom-Json
$BLOB_CONTAINER_NAME = ($StorageSettings | Where-Object name -EQ 'BLOB_CONTAINER_NAME').value
$BLOB_STORAGE_URL = ($StorageSettings | Where-Object name -EQ 'BLOB_STORAGE_URL').value

# STEP 3 - print out all the extracted values for confirmation

# print out all the values for confirmation
Write-Host "=================================="
Write-Host "Values Extracted"
Write-Host "App Host: $AppHost
"
Write-Host "Site URL: $SiteUrl"
Write-Host "Media Host: $MediaHost"
Write-Host "Media Base URL: $MediaBaseUrl"
Write-Host "Storage Account: $StorageAccount"
Write-Host "Target SQL Zip File: $TargetSQLZipFile"
Write-Host "Local SQL File: $LocalSQLFile"
Write-Host "Local SQL Clean File: $LocalSQLCleanFile"
Write-Host "Local SQL Folder: $SqlFolder"
Write-Host "Local SQL Name: $SqlName"
Write-Host "Local Work Directory: $LocalWork"
Write-Host "App Service Resource Group: $ResourceGroup"
Write-Host "App Service Name: $AppName"
Write-Host "Subscription ID: $SubscriptionId"
Write-Host "Database Host: $DATABASE_HOST"
Write-Host "Database Username: $DATABASE_USERNAME"
Write-Host "Blob Container Name: $BLOB_CONTAINER_NAME"
Write-Host "Blob Storage URL: $BLOB_STORAGE_URL"
Write-Host "WPContent Directory: $WPZipFile"
Write-Host "WPContent Full Path: $TargetWPZipFile"
Write-Host "DWM Zip File: $WDMZipFile"
Write-Host "DWM Full Path: $TargetWDMZipFile"
Write-Host "=================================="





# STEP 4 - configure access restrictions for the SCM site
# allow full access to scm site. Be sure to turn off. Per IP was being unreliable but is better



az webapp config access-restriction set `
    --resource-group $ResourceGroup --name $AppName `
    --use-same-restrictions-for-scm-site false

az resource update --resource-group $ResourceGroup --name $AppName --resource-type "Microsoft.Web/sites" --set properties.siteConfig.scmIpSecurityRestrictionsDefaultAction=Allow




# STEP 5 - test connection to the Azure WordPress site

# Simple command to test that the connection to the Azure WordPress site is working

$TestCommand = 'echo "Hello from Azure WordPress"'

.\Invoke-WpCommandv2.ps1  -ReuseTunnel `
    -ResourceGroup $ResourceGroup -AppName $AppName `
    -SubscriptionId $SubscriptionId `
    -Command $TestCommand




# STEP 6 - deploy SQL zip file to the appservice



az webapp deploy -g $ResourceGroup -n $AppName --src-path $LocalSQLZipFile --type static --target-path $TargetSQLZipFile 

# STEP 7 - unzip the SQL file on the appservice and list its contents
 

$BashCommand = @"
cd /home
unzip -o "$LocalSQLZipFile"
ls -l "$LocalSQLCleanFile"
"@

.\Invoke-WpCommandv2.ps1 -ReuseTunnel `
    -ResourceGroup $ResourceGroup -AppName $AppName `
    -SubscriptionId $SubscriptionId `
    -Command $BashCommand

# STEP 8 - clean environment by removing content from wp-content and resetting the database

$BashCommand = @'
rm -rf /home/site/wwwroot/wp-content/* 
ls /home/site/wwwroot/wp-content/

cd /home
ls -l 
ACCESS_TOKEN=$(bash /usr/local/bin/fetch-mysql-access-token.sh)
M="mysql -h $DATABASE_HOST --user $DATABASE_USERNAME --enable-cleartext-plugin --password=$ACCESS_TOKEN"
$M -e "SHOW DATABASES;"
$M -e "DROP DATABASE IF EXISTS wpmigrated;"
$M -e "SHOW DATABASES;"
'@

.\Invoke-WpCommandv2.ps1 -ReuseTunnel `
    -ResourceGroup $ResourceGroup -AppName $AppName `
    -SubscriptionId $SubscriptionId `
    -Command $BashCommand

# Visit the Frontdoor if you want.. 
Start-Process -FilePath $SiteUrl
Start-Process -FilePath $SiteUrl/wp-admin/


# END CLEAN ENVIRONMENT

# STEP 9 - deploy WP content zip file to the appservice

az webapp deploy -g $ResourceGroup -n $AppName --src-path $WPZipFile --type static --target-path $TargetWPZipFile 



# STEP 10 (option 1)- unzip the WP content zip file on the appservice to the proper wordpress directory. Simple unzip without status update
$BashCommand = @"
ls -lh "$TargetWPZipFile"
unzip -o  "$TargetWPZipFile" -d /home/site/wwwroot/wp-content/
ls /home/site/wwwroot/wp-content/
ls /home/site/wwwroot/wp-content/uploads/
"@

# STEP 10 (option 2) - unzip the WP content zip file on the appservice to the proper wordpress directory with status update. Need to test

$BashCommand = @"
ls -lh "$TargetWPZipFile"
echo "Extracting wp-content file (status every 10 seconds)..."
UNZIP_LOG=`$(mktemp) || exit 1`
SECONDS=0
unzip -o "$TargetWPZipFile" -d /home/site/wwwroot/wp-content/ > "`$UNZIP_LOG" 2>&1 &
UNZIP_PID=`$!
while kill -0 "`$UNZIP_PID" 2>/dev/null; do
    echo "Extraction running: `$SECONDS seconds elapsed. Latest activity:"
    tail -n 1 "`$UNZIP_LOG"
    du -sh /home/site/wwwroot/wp-content/
    sleep 10
done
if wait "`$UNZIP_PID"; then
    UNZIP_STATUS=0
    echo "Extraction completed in `$SECONDS seconds."
else
    UNZIP_STATUS=`$?
    echo "Extraction failed after `$SECONDS seconds (exit code `$UNZIP_STATUS)."
fi
tail -n 5 "`$UNZIP_LOG"
rm -f "`$UNZIP_LOG"
exit "`$UNZIP_STATUS"
"@



 & .\Invoke-WpCommandv2.ps1 -ReuseTunnel `
    -ResourceGroup $ResourceGroup -AppName $AppName `
    -SubscriptionId $SubscriptionId `
    -Command $BashCommand

# can run this in SSH terminal to check size 
du -sh /home/site/wwwroot/wp-content/
watch -n 20 du -sh /home/site/wwwroot/wp-content/
# Run in the SSH terminal (Bash), not PowerShell; counts files recursively, including hidden files.
# while true; do bytes=$(du -sb /home/site/wwwroot/wp-content/ | cut -f1); files=$(find /home/site/wwwroot/wp-content/ -type f | wc -l); size_pct=$(awk -v bytes="$bytes" 'BEGIN { printf "%.2f", bytes / (4.86 * 1000000000) * 100 }'); file_pct=$(awk -v files="$files" 'BEGIN { printf "%.2f", files / 44880 * 100 }'); echo "$(date '+%Y-%m-%d %H:%M:%S') - $(du -sh /home/site/wwwroot/wp-content/) (${size_pct}% of 4.86 GB) - Files: $files / 44880 (${file_pct}%)"; sleep 20; done


# STEP 11 - deploy download manager files to the appservice

az webapp deploy -g $ResourceGroup -n $AppName --src-path $WDMZipFile --type static --target-path $TargetWDMZipFile 

# STEP 12 unzip the WP content zip file on the appservice to the proper wordpress directory

# option 1- tested - simple unzip, no status update
$BashCommand = @"
ls -lh "$TargetWPZipFile"
unzip -o  "$TargetWPZipFile" -d /home/site/wwwroot/wp-content/
ls /home/site/wwwroot/wp-content/
ls /home/site/wwwroot/wp-content/uploads/
"@

# option 2 - unzip with status update, to test. Should show status of the unzip
$BashCommand = @"
ls -lh "$TargetWDMZipFile"
echo "Removing existing download manager files..."
rm -rf /home/site/wwwroot/wp-content/uploads/download-manager-files/* 
echo "Extracting download manager files (status every 30 seconds)..."
UNZIP_LOG=`$(mktemp) || exit 1
SECONDS=0
unzip -o "$TargetWDMZipFile" -d /home/site/wwwroot/wp-content/uploads/download-manager-files > "`$UNZIP_LOG" 2>&1 &
UNZIP_PID=`$!
while kill -0 "`$UNZIP_PID" 2>/dev/null; do
    echo "Extraction running: `$SECONDS seconds elapsed"
    du -sh /home/site/wwwroot/wp-content/uploads/download-manager-files
    sleep 30
done
if wait "`$UNZIP_PID"; then
    UNZIP_STATUS=0
    echo "Extraction completed in `$SECONDS seconds."
else
    UNZIP_STATUS=`$?
    echo "Extraction failed after `$SECONDS seconds (exit code `$UNZIP_STATUS)."
fi
tail -n 5 "`$UNZIP_LOG"
rm -f "`$UNZIP_LOG"
exit "`$UNZIP_STATUS"
"@

 .\Invoke-WpCommandv2.ps1 -ReuseTunnel `
    -ResourceGroup $ResourceGroup -AppName $AppName `
    -SubscriptionId $SubscriptionId `
    -Command $BashCommand


# Run in the SSH terminal (Bash), not PowerShell; counts files recursively, including hidden files.
# while true; do bytes=$(du -sb /home/site/wwwroot/wp-content/uploads/download-manager-files | cut -f1); files=$(find /home/site/wwwroot/wp-content/uploads/download-manager-files -type f | wc -l); size_pct=$(awk -v bytes="$bytes" 'BEGIN { printf "%.2f", bytes / (1.84 * 1000000000) * 100 }'); file_pct=$(awk -v files="$files" 'BEGIN { printf "%.2f", files / 790 * 100 }'); echo "$(date '+%Y-%m-%d %H:%M:%S') - $(du -sh /home/site/wwwroot/wp-content/uploads/download-manager-files) (${size_pct}% of 1.84 GB) - Files: $files / 790 (${file_pct}%)"; sleep 20; done

# STEP 13 - deploy the SQL to the database


# Escape Bash dollar signs so PowerShell only expands the local paths and database settings.
$BashCommand = @"
set -e
ls -l "$RemoteSQLCleanFile"
echo "Fetching MySQL access token..."
ACCESS_TOKEN=`$(bash /usr/local/bin/fetch-mysql-access-token.sh)
M=(mysql -h "$DATABASE_HOST" --user "$DATABASE_USERNAME" --password="`$ACCESS_TOKEN")
"`${M[@]}" -e "SHOW DATABASES;"
"`${M[@]}" -e "DROP DATABASE IF EXISTS wpmigrated;"
"`${M[@]}" -e "CREATE DATABASE wpmigrated CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci;"
echo "Importing SQL (verbose SQL output disabled)..."
SECONDS=0
"`${M[@]}" wpmigrated --init-command='SET SESSION sql_require_primary_key=0, foreign_key_checks=0, unique_checks=0' < "$RemoteSQLCleanFile" &
IMPORT_PID=`$!
while kill -0 "`$IMPORT_PID" 2>/dev/null; do
    echo "Waiting for SQL import... `${SECONDS}s elapsed"
    sleep 10
done
wait "`$IMPORT_PID" || { STATUS=`$?; echo "SQL import failed (exit `$STATUS)." >&2; exit "`$STATUS"; }
echo "SQL import completed in `${SECONDS}s. Verifying database..."
"@


.\Invoke-WpCommandv2.ps1 -ReuseTunnel `
    -ResourceGroup $ResourceGroup -AppName $AppName `
    -SubscriptionId $SubscriptionId `
    -Command $BashCommand

# STEP 14 - check to verify the database tables and post count after migration

$BashCommand = @"
set -e
ACCESS_TOKEN=`$(bash /usr/local/bin/fetch-mysql-access-token.sh)
M=(mysql -h "$DATABASE_HOST" --user "$DATABASE_USERNAME" --enable-cleartext-plugin --password="`$ACCESS_TOKEN")
"`${M[@]}" wpmigrated -e "SHOW TABLES; SELECT COUNT(*) FROM wp_posts; SELECT option_name,option_value FROM wp_options WHERE option_name IN ('siteurl','home');"
"@

.\Invoke-WpCommandv2.ps1 -ReuseTunnel `
    -ResourceGroup $ResourceGroup -AppName $AppName `
    -SubscriptionId $SubscriptionId `
    -Command $BashCommand



# STEP 15- Set the database name in the app settings for the web app to the newly created database


az webapp config appsettings set -g $ResourceGroup -n $AppName --settings DATABASE_NAME=wpmigrated

# STEP 16 - search and replace old URL with new URL in the database, dry-run

Write-Host $SiteUrl
$OldUrl = "https://www.ecdhs.gov.za"
$NewUrl= "https://ahmsdemo6.ahmedsdemo.com"
$NewUrl = $SiteUrl

$BashCommand = @"
cd /home/site/wwwroot
wp search-replace '$OldUrl' '$NewUrl' --all-tables-with-prefix --skip-columns=guid --precise --dry-run --allow-root --skip-plugins --skip-themes
"@
.\Invoke-WpCommandv2.ps1 -ReuseTunnel `
    -ResourceGroup $ResourceGroup -AppName $AppName `
    -SubscriptionId $SubscriptionId `
    -Command $BashCommand

# STEP 17 - search and replace old URL with new URL in the database, actual run

$BashCommand = @"
cd /home/site/wwwroot
wp search-replace '$OldUrl' '$NewUrl' --verbose --all-tables-with-prefix --skip-columns=guid --precise  --allow-root --skip-plugins --skip-themes
"@
.\Invoke-WpCommandv2.ps1 -ReuseTunnel `
    -ResourceGroup $ResourceGroup -AppName $AppName `
    -SubscriptionId $SubscriptionId `
    -Command $BashCommand

# STEP 18 - update WordPress core and database

$BashCommand = @"
wp core version --path=/home/site/wwwroot --allow-root
cd /home/site/wwwroot &&
wp core update --allow-root --skip-plugins --skip-themes &&
wp core update-db --allow-root --skip-plugins --skip-themes
wp core version --path=/home/site/wwwroot --allow-root
"@

.\Invoke-WpCommandv2.ps1 -ReuseTunnel `
    -ResourceGroup $ResourceGroup -AppName $AppName `
    -SubscriptionId $SubscriptionId `
    -Command $BashCommand

# STEP 19 - install and activate necessary plugins

$BashCommand = @"
cd /home/site/wwwroot
wp core version --path=/home/site/wwwroot --allow-root
wp plugin install w3-total-cache wp-smushit --allow-root --skip-plugins --skip-themes
wp plugin activate w3-total-cache wp-smushit --allow-root --skip-plugins --skip-themes
wp plugin get w3-total-cache --fields=name,status,version --allow-root --skip-plugins --skip-themes
wp plugin get wp-smushit --fields=name,status,version --allow-root --skip-plugins --skip-themes
"@

.\Invoke-WpCommandv2.ps1 -ReuseTunnel `
    -ResourceGroup $ResourceGroup -AppName $AppName `
    -SubscriptionId $SubscriptionId `
    -Command $BashCommand

# STEP 19b - update all plugins and themes
$BashCommand = @"
wp plugin update --all --path=/home/site/wwwroot --allow-root
wp theme update --all --path=/home/site/wwwroot --allow-root
"@
.\Invoke-WpCommandv2.ps1 -ReuseTunnel `
    -ResourceGroup $ResourceGroup -AppName $AppName `
    -SubscriptionId $SubscriptionId `
    -Command $BashCommand



$BashCommand = @"
wp user create recoveryadmin admin@example.com \
  --role=administrator \
  --user_pass='P2ssword!' \
  --path=/home/site/wwwroot \
  --allow-root
"@
.\Invoke-WpCommandv2.ps1 -ReuseTunnel `
    -ResourceGroup $ResourceGroup -AppName $AppName `
    -SubscriptionId $SubscriptionId `
    -Command $BashCommand




Write-Host $WebsiteEndpointName
wordpressdhsprodafdfcy7ke2sa3mgk-ftdufrhng8d5g7f5.b02.azurefd.net

$WebsiteEndpointName="wordpressdhsprodafdfcy7ke2sa3mgk"

# STEP 21 - do a purge of frontdoor url

az afd endpoint purge --resource-group $AFDResourceGroup `
    --profile-name $FrontDoorProfileName `
    --endpoint-name $WebsiteEndpointName --content-paths '/*'


# do a purge of frontdoor custom domain. review below


# STEP 22 - stop appservice in case and start again
az webapp stop -g $ResourceGroup -n $AppName
az webapp start -g $ResourceGroup -n $AppName

Start-Process -FilePath $SiteUrl
Start-Process -FilePath $SiteUrl/phuma/
Start-Process -FilePath $SiteUrl/wp-admin/

# STEP 23
Setup custom domain manually

# STEP 24 - set CUSTOM_DOMAIN app setting and purge custom domain
$CUSTOMDOMAINURL="ecdhs2.ahmedsdemo.com" # replace with your custom domain URL
Write-Output $CUSTOMDOMAINURL
az webapp config appsettings set -g $ResourceGroup -n $AppName --settings CUSTOM_DOMAIN=$CUSTOMDOMAINURL

# STEP 25 - update the URL with search and replace in the WordPress database
# option 1
# update the URL with search and replace in the WordPress database
# Seems better to install the better search-replace plugin if not already installed and then use it for the search and replace operation
$BashCommand = @"
cd /home/site/wwwroot
wp plugin install better-search-replace --activate --allow-root
"@
.\Invoke-WpCommandv2.ps1 -ReuseTunnel `
    -ResourceGroup $ResourceGroup -AppName $AppName `
    -SubscriptionId $SubscriptionId `
    -Command $BashCommand

# option 2. manually use the wp cli for search and replace operation
Write-Host $SiteUrl
$OldUrl = $SiteUrl
$NewUrl = "https://$CUSTOMDOMAINURL"

$BashCommand = @"
cd /home/site/wwwroot
wp search-replace '$OldUrl' '$NewUrl' --all-tables-with-prefix --skip-columns=guid --precise --dry-run --allow-root --skip-plugins --skip-themes
"@
.\Invoke-WpCommandv2.ps1 -ReuseTunnel `
    -ResourceGroup $ResourceGroup -AppName $AppName `
    -SubscriptionId $SubscriptionId `
    -Command $BashCommand


# STEP 26 - purge both the default endpoint and the custom domain endpoint

az afd endpoint purge --resource-group $AFDResourceGroup `
    --profile-name $FrontDoorProfileName `
    --endpoint-name $WebsiteEndpointName --content-paths '/*'


az afd endpoint purge --resource-group $AFDResourceGroup `
    --profile-name $FrontDoorProfileName `
    --endpoint-name $WebsiteEndpointName `
    --domains $CUSTOMDOMAINURL `
    --content-paths '/*'

# STEP 27 need to disable the frontdoor endpoint for the built in domain so users can use custom domain


az afd route update `
    --resource-group $AFDResourceGroup `
    --profile-name $FrontDoorProfileName `
    --endpoint-name $WebsiteEndpointName `
    --route-name wordpress `
    --link-to-default-domain Disabled


# if you need enable original domain

az afd route update `
    --resource-group $AFDResourceGroup `
    --profile-name $FrontDoorProfileName `
    --endpoint-name $WebsiteEndpointName `
    --route-name wordpress `
    --link-to-default-domain Enabled


# STEP 28 - reset SCM site to Deny

az resource update --resource-group $ResourceGroup --name $AppName --resource-type "Microsoft.Web/sites" --set properties.siteConfig.scmIpSecurityRestrictionsDefaultAction=Deny

# this should fail now

$TestCommand = 'echo "Hello from Azure WordPress"'

.\Invoke-WpCommandv2.ps1  -ReuseTunnel `
    -ResourceGroup $ResourceGroup -AppName $AppName `
    -SubscriptionId $SubscriptionId `
    -Command $TestCommand