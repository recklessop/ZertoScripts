################################################
# Configure the variables below
################################################
$LogDataDir = "PathToLogDirectory"
$ESXiHostCSV = "PathTo\VRADeploymentESXiHosts.csv"
$ZertoServer = "IPAddressOfZVM"
$ZertoPort = "9669"
$ZertoUser = "account@domain.local"
$ZertoPassword = "password"
$SecondsBetweenVRADeployments = "120"
##################################################################################
# Nothing to configure below this line - Starting the main function of the script
##################################################################################
################################################
# Setting log directory for engine and current month
################################################
$CurrentMonth = get-date -format MM.yy
$CurrentTime = get-date -format hh.mm.ss
$CurrentLogDataDir = $LogDataDir + $CurrentMonth
$CurrentLogDataFile = $LogDataDir + $CurrentMonth + "\BulkVPGCreationLog-" + $CurrentTime + ".txt"
# Testing path exists to engine logging, if not creating it
$ExportDataDirTestPath = test-path $CurrentLogDataDir
if ($ExportDataDirTestPath -eq $False)
{
New-Item -ItemType Directory -Force -Path $CurrentLogDataDir
}
start-transcript -path $CurrentLogDataFile -NoClobber
################################################
# Setting Cert Policy - required for successful auth with the Zerto API
################################################
add-type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
public bool CheckValidationResult(
ServicePoint srvPoint, X509Certificate certificate,
WebRequest request, int certificateProblem) {
return true;
}
}
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
################################################
# Building Zerto API string and invoking API
################################################
$baseURL = "https://" + $ZertoServer + ":"+$ZertoPort+"/v1/"
# Authenticating with Zerto APIs
$xZertoSessionURI = $baseURL + "session/add"
$authInfo = ("{0}:{1}" -f $ZertoUser,$ZertoPassword)
$authInfo = [System.Text.Encoding]::UTF8.GetBytes($authInfo)
$authInfo = [System.Convert]::ToBase64String($authInfo)
$headers = @{Authorization=("Basic {0}" -f $authInfo)}
$sessionBody = '{"AuthenticationMethod": "1"}'
$contentType = "application/json"
$xZertoSessionResponse = Invoke-WebRequest -Uri $xZertoSessionURI -Headers $headers -Method POST -Body $sessionBody -ContentType $contentType
#Extracting x-zerto-session from the response, and adding it to the actual API
$xZertoSession = $xZertoSessionResponse.headers.get_item("x-zerto-session")
$zertoSessionHeader = @{"x-zerto-session"=$xZertoSession}
# Get SiteIdentifier for getting Network Identifier later in the script
$SiteInfoURL = $BaseURL+"localsite"
$SiteInfoCMD = Invoke-RestMethod -Uri $SiteInfoURL -TimeoutSec 100 -Headers $zertoSessionHeader -ContentType "application/JSON"
$SiteIdentifier = $SiteInfoCMD | Select SiteIdentifier -ExpandProperty SiteIdentifier
$VRAInstallURL = $BaseURL+"vras"
################################################
# Importing the CSV of ESXi hosts to deploy VRA to
################################################
$ESXiHostCSVImport = Import-Csv $ESXiHostCSV
################################################
# Starting Install Process for each ESXi host specified in the CSV
################################################
foreach ($ESXiHost in $ESXiHostCSVImport)
{
# Setting variables for ease of use throughout script
$VRAESXiHostName = $ESXiHost.ESXiHostName
$VRADatastoreName = $ESXiHost.DatastoreName
$VRAPortGroupName = $ESXiHost.PortGroupName
$VRAGroupName = $ESXiHost.VRAGroupName
$VRAMemoryInGB = $ESXiHost.MemoryInGB
$VRADefaultGateway = $ESXiHost.DefaultGateway
$VRASubnetMask = $ESXiHost.SubnetMask
$VRAIPAddress = $ESXiHost.VRAIPAddress
# Get NetworkIdentifier for API
$VISiteInfoURL = $BaseURL+"virtualizationsites/$SiteIdentifier/networks"
$VISiteInfoCMD = Invoke-RestMethod -Uri $VISiteInfoURL -TimeoutSec 100 -Headers $zertoSessionHeader -ContentType "application/JSON"
$NetworkIdentifier = $VISiteInfoCMD | Where-Object {$_.VirtualizationNetworkName -eq $VRAPortGroupName} | Select NetworkIdentifier -ExpandProperty NetworkIdentifier
$NetworkIdentifier = $NetworkIdentifier.NetworkIdentifier
# Get HostIdentifier for API
$VISiteInfoURL = $BaseURL+"virtualizationsites/$SiteIdentifier/hosts"
$VISiteInfoHostCMD = Invoke-RestMethod -Uri $VISiteInfoURL -TimeoutSec 100 -Headers $zertoSessionHeader -ContentType "application/JSON"
$VRAESXiHostID = $VISiteInfoHostCMD | Where-Object {$_.VirtualizationHostName -eq $VRAESXiHostName} | Select HostIdentifier -ExpandProperty HostIdentifier
$VRAESXiHostID = $VRAESXiHostID.HostIdentifier
# Get DatastoreIdentifier for API
$VISiteInfoURL = $BaseURL+"virtualizationsites/$SiteIdentifier/datastores"
$VISiteInfoCMD = Invoke-RestMethod -Uri $VISiteInfoURL -TimeoutSec 100 -Headers $zertoSessionHeader -ContentType "application/JSON"
$VRADatastoreID = $VISiteInfoCMD | Where-Object {$_.DatastoreName -eq $VRADatastoreName} | Select DatastoreIdentifier -ExpandProperty DatastoreIdentifier
$VRADatastoreID = $VRADatastoreID.DatastoreIdentifier
# Creating JSON Body for API settings
$JSON =
"{
""DatastoreIdentifier"": ""$VRADatastoreID"",
""GroupName"": ""$VRAGroupName"",
""HostIdentifier"": ""$VRAESXiHostID"",
""HostRootPassword"":null,
""MemoryInGb"": ""$VRAMemoryInGB"",
""NetworkIdentifier"": ""$NetworkIdentifier"",
""UsePublicKeyInsteadOfCredentials"":true,
""VraNetworkDataApi"": {
""DefaultGateway"": ""$VRADefaultGateway"",
""SubnetMask"": ""$VRASubnetMask"",
""VraIPAddress"": ""$VRAIPAddress"",
""VraIPConfigurationTypeApi"": ""Static""
}
}"
write-host "Executing $JSON"
# Now trying API install cmd
Try
{
Invoke-RestMethod -Method Post -Uri $VRAInstallURL -Body $JSON -ContentType $ContentType -Headers $zertoSessionHeader
}
Catch {
Write-Host $_.Exception.ToString()
$error[0] | Format-List -Force
}
# Waiting xx seconds before deploying the next VRA
write-host "Waiting $SecondsBetweenVRADeployments seconds before deploying the next VRA or stopping"
sleep $SecondsBetweenVRADeployments
# End of per Host operations below
}
# End of per Host operations above
################################################
# Stopping logging
################################################
Stop-Transcript