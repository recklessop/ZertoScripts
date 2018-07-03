########################################################################################################################
# Start of the script - Description, Requirements & Legal Disclaimer
########################################################################################################################
# Written by: Joshua Stenhouse joshua@zerto.com +44 7834 344 838
################################################
# Description:
# Welcome to the Zerto MSCS Cluster Support Script
# This script is designed for MSCS clusters using shared RDMs where only the active Primary node is protected in a VPG
# For help in scheduling the PowerShell script consult any example such as the below:
# https://support.software.dell.com/appassure/kb/144451
################################################ 
# Requirements:
# - ZVM ServerName, seperate Usernames and passwords with permission to access the Powershell CMDlets and API of the ZVM
# - Network access to the ZVM
# - Zerto PowerShell cmdlets to insert checkpoints and pause/unpause VPGs
# - When the protected node VPG is first created it should be the active node throughout the initial sync to ensure the initial copy of the VM is in a consistent state
# - Server 2008 + with execution policy set to remote signed, recommended to be set on both x64 and x86 powershell after running as administrator
# - Access permission to write in and create (or create it manually and ensure the user has permission to write within)the directory specified for logging
# - Run PowerShell as administrator with command "Set-ExecutionPolcity unrestricted"
# - Active/passive MSCS cluster using shared RDM disks, shared VMDKs are not supported by Zerto or the script
# - Powershell 3.0 installed
# - Maximum 2 nodes in the cluster
# - Only 1 active service on the cluster, if using multiple services they must be interdependent to ensure they stay on the same node at all times
# - Recommended to configure primary node configured with auto failback (as you will not be protected when running on the secondary node) but this can be done manually if preferred
# - Recommended to configure the cluster services with enable persistent mode and un tick auto start on the general settings on each service. This ensure that if the cluster is completely rebooted you can start the cluster on the protected node first either automatically with persistent and auto ticked, or manually with persistent ticked and auto unticked.
# - Failure to configure the above setting can mean that in the event of a cluster being completely rebooted (both nodes) the service could start on the 2nd node, before the primary node VPG is in sync which means the script will fail to pause the VPG automatically. If you have to start the cluster on the 2nd node paused the VPG manually when the initial sync in Zerto has finished.
# - This script should be run on both cluster nodes every 1-5 minute2. It is not recommended to this run less frequently than every 5 minutes as the active node could switch both ways and Zerto would not see this, causing this VPG to go into an inconsistent state.
################################################
# Notes:
# This script is designed for MSCS clusters where only the active Primary node is protected in a VPG
# For failover testing a SQL cluster node VPG you need to have active directory running in the same isolated network with both DNS/GC services set as the primary or secondary DNS on the protected cluster node. You cannot test failover MSCS without AD being online at least 5 minutes in advance in the isolated test network. 
# It is therefore recommended to have a local AD server to the MSCS cluster in a VPG, separate to the MSCS VPG for best practice, replicating to the recovery site for failover testing.
# If you are failing over to a remote site with a separate IP subnet then it is recommended to replicate a local AD server in the target site between 2 hosts (enabled with the replicate to self option in advanced Zerto settings) so you can easily bring a copy of AD online in the test failover network to simulate real failover of MSCS.
################################################
# Legal Disclaimer:
# This script is written by Joshua Stenhouse is not supported under any Zerto support program or service. 
# All scripts are provided AS IS without warranty of any kind. 
# The author and Zerto further disclaims all implied warranties including, without limitation, any implied warranties of merchantability or of fitness for a particular purpose. 
# The entire risk arising out of the use or performance of the sample scripts and documentation remains with you. 
# In no event shall Zerto, its authors, or anyone else involved in the creation, production, or delivery of the scripts be liable for any damages whatsoever (including, without limitation, damages for loss of business profits, business interruption, loss of business information, or other pecuniary loss) arising out of the use of or inability to use the sample scripts or documentation, even if the author or Zerto has been advised of the possibility of such damages.
################################################
################################################
# Configure the variables below
################################################
# Step 1. Configure the hostname of both nodes in the Microsoft cluster.
$node1name = "sql2008server1"
$node2name = "sql2008server2"
# Step 2. Configure exact name of the cluster service running on the Microsoft cluster. If running multiple services specify the master service upon which all other services are dependant on.
$sqlclustername = "sql server (MSSQLSERVER)"
# Step 3. Configure the name of the VPG in Zerto which is protecting the primary active node. Recommended to not use spaces in the VPG name.
$node1vpgname = "sql2008server1"
# Step 4. Configure the IP address of the ZVM and the PowerShell login credentials
$ZVMIP = "192.168.0.116"
$ZertoUser = "root"
$ZertoPassword = "Zerto123"
$ZVMPowerShellPort = "9080"
# Step 5. Configure the username and password for the ZVM that can login to the ZVM interface, for the API calls to use to get the VPG status
$ZertoAPIPort = "9669"
$ZertoAPIUser = "administrator@lab.local"
$ZertoAPIPassword = "Srt1234!"
# Step 6. Configure the log file location. This should be accessible to the node running the script at all times, irrespective of cluster owner. A c drive or server share is recommended.
# Important - create the directory below otherwise the script will fail to run. A check can be added to re-create these if deemed necessary. 
$loggingfilepath = "C:\Zerto_Scripts\Logs\"
# Step 7. Configure email settings for email alerts, emails will only be sent if a change is made
$emailto = "test@lab.local"
$emailfrom = "alert@lab.local"
$smtpserver = "192.168.0.1"
########################################################################################################################
# Nothing to configure below this line - Starting the main function of the script
########################################################################################################################
################################################
# Setting log directory for engine and current month
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
$baseURL = "https://" + $ZVMIP + ":"+$ZertoAPIPort+"/v1/"
# Authenticating with Zerto APIs
$xZertoSessionURI = $baseURL + "session/add"
$authInfo = ("{0}:{1}" -f $ZertoAPIUser,$ZertoAPIPassword)
$authInfo = [System.Text.Encoding]::UTF8.GetBytes($authInfo)
$authInfo = [System.Convert]::ToBase64String($authInfo)
$headers = @{Authorization=("Basic {0}" -f $authInfo)}
$sessionBody = '{"AuthenticationMethod": "1"}'
$contentType = "application/json"
Try 
{
$xZertoSessionResponse = Invoke-WebRequest -Uri $xZertoSessionURI -Headers $headers -Method POST -Body $sessionBody -ContentType $contentType
}
Catch {
Write-Host $_.Exception.ToString()
$error[0] | Format-List -Force
}
# Extracting x-zerto-session from the response, and adding it to the actual API
$xZertoSession = $xZertoSessionResponse.headers.get_item("x-zerto-session")
$zertoSessionHeader = @{"x-zerto-session"=$xZertoSession}
################################################
# Adds the Zerto Powershell and Windows Failover Cluster cmdlets used to check the active cluster node and then perform Zerto operations
################################################
function LoadSnapin{
  param($PSSnapinName)
  if (!(Get-PSSnapin | where {$_.Name   -eq $PSSnapinName})){
    Add-pssnapin -name $PSSnapinName
  }
}
LoadSnapin -PSSnapinName   "Zerto.PS.Commands"
Import-Module Failoverclusters
################################################
# Getting current date and setting log file location, the current hostname and naming convention
################################################
$currenthost = hostname
$now = Get-Date
$time = $now.ToString("HH:mm:ss")
$logFile = $loggingfilepath + "\Zerto-ConsistencyLog-" + $node1vpgname + "-" + $now.ToString("yyyy-MM-dd") + ".log"
################################################
# Selects the current cluster owner using the Windows Failover Cluster cmdlets
################################################
$getowner = (get-clustergroup -name $sqlclustername | select -expandproperty OwnerNode)
$currentowner = ($getowner | select -expandproperty Name)
################################################
# Checks to see if Node 1 VPG is paused via the API
################################################
# Build List of VPGs
$vpgListApiUrl = $baseURL+"vpgs"
$vpgList = Invoke-RestMethod -Uri $vpgListApiUrl -TimeoutSec 100 -Headers $zertoSessionHeader -ContentType "application/xml"
# Building VPG array 
$zertovpgarray = $vpgList.ArrayOfVpgApi.VpgApi | Where-object {$_.VpgName -eq $node1vpgname} | Select-Object VpgName,VpgIdentifier,Status,SubStatus
# Setting the status of the VPG
$zertovpgName = $zertovpgarray.VpgName
$zertovpgIdentifier = $zertovpgarray.VpgIdentifier
$zertovpgStatus = $zertovpgarray.Status
$zertovpgSubStatus = $zertovpgarray.SubStatus
# If statement to set pause status
if ($zertovpgSubStatus -eq "ReplicationPausedUserInitiated")
{
$node1paused = $True
}
else
{
$node1paused = $False
}
########################################################################################################################
# To explain the logic of the below:
# Task Group 1. If the VPG is paused and node 1 owner as the protected node has resumed ownership of the cluster after a failover and so the VPG is resumed, a checkpoint is set for visibility and a delta-sync is performed to get the VPG back into a consistent stae.
# Task Group 2. If the VPG is not paused, but node 2 is the owner a failover has occured in the cluster. the VPG is no longer consistent and so it is paused and a checkpoint inserted for visibility in the ZVM.
# Task Group 3.
# If the VPG is paused and node 2 owner = No task to Run as the VPG is paused, node 2 is the owner which means the cluster is not being protected by Zerto as the protected node is not active.
# If the VPG is not paused and node 1 is the owner  = No task to Run as there is nothing to do, the active cluster node is protected by Zerto. 
########################################################################################################################
################################################
# Task Group 1 - Node 1 checks if node 1 is paused and the cluster owner
################################################
if (($node1paused -eq $True) -And ($currentowner -eq $node1name))
{
# Unpausing the VPG
Resume-ProtectionGroup -ZVMIP $ZVMIP -ZVMPORT $ZVMPowerShellPort -Username $ZertoUser -password $ZertoPassword -VirtualProtectionGroup $node1vpgname -Wait 300 -confirm:$false
# Inserting action into the log
$action = $time + " Run on " + $currenthost + "-" + "Task Group 1 - Resumed VPG - " + $node1vpgname + " - Reason - The VPG is paused yet the primary active node is now " + $node1name + " and so the VPG has been resumed."
$action | Out-File -filePath $logFile -Append
# Waiting for pause to finish
Start-Sleep 10
# Add checkpoint for visibility in the ZVM
Set-Checkpoint -ZVMIP $ZVMIP -ZVMPORT $ZVMPowerShellPort -Username $ZertoUser -password $ZertoPassword  -VirtualProtectionGroup $node1vpgname -Wait 300 -confirm:$false -Tag "NOW Cluster Owner - Auto Force Sync Started"
# Inserting action into the log
$action = $time + " Run on " + $currenthost + "-" + " Task Group 1 - Inserted Checkpoint in VPG - " + $node1vpgname + " - Reason - The VPG is paused yet the primary active node is now " + $node1name + ", Zerto is now about to perform a force sync. The checkpoint indicates when this process started in the journal of changes."
$action | Out-File -filePath $logFile -Append
Start-Sleep 3
# Perform delta sync to maintain consistency
Force-Sync -ZVMIP $ZVMIP -ZVMPORT $ZVMPowerShellPort -Username $ZertoUser -password $ZertoPassword  -VirtualProtectionGroup $node1vpgname -Wait 300 -confirm:$false
# Inserting action into the log
$action = $time + " Run on " + $currenthost + " Run on " + $currenthost + "-" + " Task Group 1 - Force Sync Initiated on VPG - " + $node1vpgname + " - Reason - The VPG is paused yet the primary active node is now " + $node1name + ", Zerto is has initiated a force sync to get the VM back into a consistent state allowing failover."
$action | Out-File -filePath $logFile -Append
# Sending notification email
$EmailMessage = $action
send-mailmessage -from $emailfrom -to $emailto -subject "MSCS Script Alert" -BodyAsHTML -body $EmailMessage -priority Normal -smtpServer $smtpserver
}
################################################
# Task Group 2 - This checks if the node isn't paused and if it isn't the cluster owner
################################################
if (($node1paused -eq $False) -And ($currentowner -eq $node2name))
{
# Inserting checkpoint for visibility in the ZVM
Set-Checkpoint -ZVMIP $ZVMIP -ZVMPORT $ZVMPowerShellPort -Username $ZertoUser -password $ZertoPassword  -VirtualProtectionGroup $node1vpgname -Wait 300 -confirm:$false -Tag "NOT Cluster Owner - Auto Paused"
# Inserting action into the log
$action = $time + " Run on " + $currenthost + "-" + " Task Group 2 - Inserted Checkpoint in VPG - " + $node1vpgname + " - Reason - The VPG was not paused, yet the active node is now " + $node2name + ", Zerto is now about to suspend the VPG as it can no longer failover consistently. The checkpoint indicates when this occurred in the journal of changes."
$action | Out-File -filePath $logFile -Append
# As node 1 is not the Owner it pauses the VPG 
Pause-ProtectionGroup -ZVMIP $ZVMIP -ZVMPORT $ZVMPowerShellPort -Username $ZertoUser -password $ZertoPassword -VirtualProtectionGroup $node1vpgname -Wait 300 -confirm:$false
# Inserting action into the log
$action = $time + " Run on " + $currenthost + "-" + " Task Group 2 - Paused VPG - " + $node1vpgname + " - Reason - The VPG was not paused, yet the active node is now " + $node2name + " and so the VPG has been paused."
$action | Out-File -filePath $logFile -Append
# Sending notification email
$EmailMessage = $action
send-mailmessage -from $emailfrom -to $emailto -subject "MSCS Script Alert" -BodyAsHTML -body $EmailMessage -priority Normal -smtpServer $smtpserver
}
else {
################################################
# Task Group 3 - No task to Run as there is nothing to do
################################################
if ($node1paused -eq $False)
{$nodepausedoutcome = "Replicating"}
if($node1paused -eq $True)
{$nodepausedoutcome = "Paused"}
# Inserting log entry that nothing ran because either:
# If the VPG is paused and node 2 owner = No task to Run as the VPG is paused, node 2 is the owner which means the cluster is not being protected by Zerto as the protected node is not active.
# If the VPG is not paused and node 2 owner = Runs Task 2 which pauses the VPG, sets a checkpoint for visibility
$action = $time + " Run on " + $currenthost + " - No action needed. Current active node is " + $currentowner + " and the VPG is " + $nodepausedoutcome
$action | Out-File -filePath $logFile -Append
}


