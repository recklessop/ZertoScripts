#################################################################
# ZVMEmailAlerts.ps1
# 
# By Justin Paul, Zerto Technical Alliances Architect
# Contact info: jp@zerto.com
# Repo: https://www.github.com/recklessop/ZertoScripts
#
# This script looks for Alerts in ZVM in the "Warning" and " Error"status 
# then adds the event infromation to the windwos Event Log.
#
# In order to Generate an Encrypted password for the $strZVMPwd field use the passEncrypt.ps1 script, 
# and paste the data in c:\passwd.txt to the variable.
#
# For a list of warnings see this PDF
# http://s3.amazonaws.com/zertodownload_docs/Latest/Guide%20to%20Alarms,%20Alerts%20and%20Events.pdf
#
# Note this script is provided as-is and comes with no warranty.
# The author takes no responsability for dataloss or corruption of any kind.
# Also this script is not supported by Zerto Technical Support.
#
# With that said, the script only uses "GET" commands so you should be pretty safe.
#
#################################################################

################ Variables for your script ######################

$strZVMIP = "172.16.1.20"
$strZVMPort = "9669"

$strZVMUser = "administrator@vsphere.local"
$strZVMPwd = "" #run passEncrypt.ps1 on same machine as this script to generate encrypted password then paste into the quotes from c:\passwd.txt

# this code decrypts the password at runtime using the unique system Key. 
$strZVMPwd = $strZVMPwd | convertto-securestring 
$strZVMPwd = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($strZVMPwd)
$strZVMPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($strZVMPwd)

############### ignore self signed SSL ##########################
if (-not ([System.Management.Automation.PSTypeName]'ServerCertificateValidationCallback').Type)
{
$certCallback = @"
    using System;
    using System.Net;
    using System.Net.Security;
    using System.Security.Cryptography.X509Certificates;
    public class ServerCertificateValidationCallback
    {
        public static void Ignore()
        {
            if(ServicePointManager.ServerCertificateValidationCallback ==null)
            {
                ServicePointManager.ServerCertificateValidationCallback += 
                    delegate
                    (
                        Object obj, 
                        X509Certificate certificate, 
                        X509Chain chain, 
                        SslPolicyErrors errors
                    )
                    {
                        return true;
                    };
            }
        }
    }
"@
    Add-Type $certCallback
 }
[ServerCertificateValidationCallback]::Ignore()
#################################################################

## Perform authentication so that Zerto APIs can run. Return a session identifier that needs tobe inserted in the header for subsequent requests.
function getxZertoSession ($userName, $password){
    $baseURL = "https://" + $strZVMIP + ":" + $strZVMPort
    $xZertoSessionURL = $baseURL +"/v1/session/add"
    $authInfo = ("{0}:{1}" -f $userName,$password)
    $authInfo = [System.Text.Encoding]::UTF8.GetBytes($authInfo)
    $authInfo = [System.Convert]::ToBase64String($authInfo)
    $headers = @{Authorization=("Basic {0}" -f $authInfo)}
    $contentType = "application/json"
    $xZertoSessionResponse = Invoke-WebRequest -Uri $xZertoSessionURL -Headers $headers -Method POST -ContentType $contentType

    return $xZertoSessionResponse.headers.get_item("x-zerto-session")
}

#Extract x-zerto-session from the response, and add it to the actual API:
$xZertoSession = getxZertoSession $strZVMUser $strZVMPwd
$zertoSessionHeader = @{"x-zerto-session"=$xZertoSession}
$zertoSessionHeader_xml = @{"Accept"="application/xml"
"x-zerto-session"=$xZertoSession}

################ Your Script starts here #######################
#Invoke the Zerto API:
$peerListApiUrl = "https://" + $strZVMIP + ":"+$strZVMPort+"/v1/alerts"

#Iterate with JSON:
$alertListJSON = Invoke-RestMethod -Uri $peerListApiUrl -Headers $zertoSessionHeader
foreach ($alert in $alertListJSON){
	if ($alert.Level -eq "Warning" -Or $alert.Level -eq "Error")
	{
        $EventBody = ""
	    $vpgAlertAcked = $alert.IsDismissed
	    $vpgAlertDate = $alert.TurnedOn
	    $vpgAlertDesc = $alert.Description
	    $theVPG = $alert.AffectedVPGs;
	    if ($vpgAlertAcked -ne "True"){
            $EventBody = "A Zerto Alert has been discovered! `n---------------------`n"
            $EventBody += $alert.HelpIdentifier + "`n"
            $EventBody += $vpgAlertDesc + "`n---------------------`n"

	        foreach ($VPG in $theVPG){
		        $name = $VPG.identifier
	            $EventBody += "This Alert is affecting the following VPGs:`n`n"
		        $vpgNameUrl = "https://" + $strZVMIP + ":"+$strZVMPort+"/v1/vpgs/"+$name
		        $vpgNameJSON = Invoke-RestMethod -Uri $vpgNameUrl -Headers $zertoSessionHeader

		        $vpgName = $vpgNameJSON.VpgName
		        $vpgActRPO = $vpgNameJSON.ActualRPO
		        $vpgConfRPO = $vpgNameJSON.ConfiguredRpoSeconds
		        $vpgSourceSite = $vpgNameJSON.SourceSite
		        $vpgTargetSite = $vpgNameJSON.TargetSite
		        $vpgVMCount = $vpgNameJSON.VmsCount
		        $vpgStatus = $vpgNameJSON.Status

		        $EventBody += "VPG Name: $vpgName`n"
		        $EventBody += "Source Site: $vpgSourceSite`n"
	    	    $EventBody += "Recovery Site: $vpgTargetSite`n"
	    	    $EventBody += "Current RPO: $vpgActRPO`n"
	    	    $EventBody += "Configured RPO SLA not to exceed (seconds): $vpgConfRPO`n"
	    	    $EventBody += "Number of Protected VMs in VPG: $vpgVMCount`n"
		        $EventBody += "Has someone acknoledged the alert? $vpgAlertAcked`n"  
		    }
	    }
        $zID = $alert.HelpIdentifier -replace "[^0-9]"
        Write-EventLog -LogName "Application" -source "Zerto" -EventID $zID -EntryType $alert.Level -Message $EventBody
	}
}

##End of script
