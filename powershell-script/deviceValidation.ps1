# ===================================================================
# Pre-Execution Check
# This script is run by a scheduled task. It will check if the device
# is ready before running the full validation
# ===================================================================

$scriptname = "deviceValidation"
$LogFolder = [System.IO.Path]::Combine("${env:systemdrive}\", "it_logs")
$LogFile = [System.IO.Path]::Combine("${LogFolder}\", "CiscoIT_${scriptname}.log")
$scriptver = "4.0"

Function LogWrite {
    Param ([string]$logstring)
    $time = get-date -Format "yyyy-MM-dd HH:mm:ss"
    $logstring = "${time} - ${logstring}"
    $logstring
    Add-content ${Logfile} -value ${logstring}
}
if (-not(test-path ${LogFolder})) { mkdir ${LogFolder} }

$taskName = "Cisco-DeviceValidation-Task"
$deviceValidationKey = 'HKLM:\Software\Cisco Internal\Intune\DeviceValidation'
$maxUploadRetries = 3


logwrite "=========================================="
logwrite "Script execution started"

# Ensure registry paths exist
$pathsToEnsure = @(
    'HKLM:\Software\Cisco Internal',
    'HKLM:\Software\Cisco Internal\Intune',
    $deviceValidationKey
)
foreach ($path in $pathsToEnsure) {
    if (-not (Test-Path $path)) {
        New-Item -Path $path -Force | Out-Null
    }
}

# first time check
$startTimeValue = Get-ItemProperty -Path $deviceValidationKey -Name "StartTime" -ErrorAction SilentlyContinue
if ($null -eq $startTimeValue.StartTime) {
    logwrite "Validation timer not found in registry. Timer should have been set during installation. Setting timer now."
    $startTime = Get-Date
    New-ItemProperty -Path $deviceValidationKey -Name "StartTime" -Value $startTime.ToString("yyyy-MM-dd HH:mm:ss") -PropertyType String -Force | Out-Null
    logwrite "Will run full validation after 60 minutes."
    exit 0 
}

# Check if this is a retry run first
$uploadRetryCount = Get-ItemProperty -Path $deviceValidationKey -Name "RetryCount" -ErrorAction SilentlyContinue
$isRetryRun = $false
if ($uploadRetryCount -and $uploadRetryCount.RetryCount -gt 0) {
    $isRetryRun = $true
    $currentRetries = [int]$uploadRetryCount.RetryCount
    logwrite "Upload retry attempt $currentRetries of $maxUploadRetries"
    
    if ($currentRetries -ge $maxUploadRetries) {
        logwrite "Maximum upload retries reached ($maxUploadRetries). Cleaning up and exiting."
        # Clean up registry and task
        Remove-ItemProperty -Path $deviceValidationKey -Name "StartTime" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $deviceValidationKey -Name "RetryCount" -ErrorAction SilentlyContinue
        
        $taskExists = schtasks.exe /Query /TN $taskName 2>$null
        if ($LASTEXITCODE -eq 0) {
            schtasks.exe /Delete /TN $taskName /F | Out-Null
            logwrite "Scheduled task deleted after max retries."
        }
        exit 1
    }
    
    # Skip timer check for retry runs
    logwrite "Skipping 60-minute timer check for retry run - proceeding directly to upload."
}
else {
    # Only check timer for first-time runs, check if 30 mins have passed
    try {
        $startTime = [DateTime]::ParseExact($startTimeValue.StartTime, "yyyy-MM-dd HH:mm:ss", $null)
        $timeSinceStart = New-TimeSpan -Start $startTime -End (Get-Date)

        if ($timeSinceStart.TotalMinutes -lt 60) {
            logwrite "Waiting period not yet complete. Time elapsed: $([Math]::Round($timeSinceStart.TotalMinutes, 2)) minutes. Will retry on next schedule."
            exit 0
        }
    }
    catch {
        logwrite "Error parsing registry start time: $_. Proceeding with validation."
    }
}

if ($isRetryRun) {
    logwrite "Skipping validation tests - retry upload only."
}
else {
    logwrite "Device is ready. Running full validation..."
}

$windowsVersion = "25H2"
$secureClientVersion = ""
$secureEndpointVersion = "8.4.5.30483"
$duoDesktopVersion = "7.11.0.0"
$webexVersion = "45.7.0.32689"
$webexVersionVM = "45.4.0.32217"
$druvaVersion = "7.5.7.0"

$sysResetExists = $false
if ($true -eq (Test-Path -Path ([System.IO.Path]::Combine(${env:SystemDrive}, "SysReset")))) {
    $sysResetExists = $true
}


function Add-Pass {
    param([string]$message)
    logwrite "${message} [PASS]"
    $script:passCount++
}

function Add-Fail {
    param([string]$message)
    logwrite "${message} [FAIL]"
    $script:failCount++
}

function Add-Info {
    param([string]$message)
    LogWrite "${message} [INFO]"
}

function Test-IsNumeric {
    param([string]$Value)
    $parsedValue = $null
    return [double]::TryParse($Value, [ref]$parsedValue)
}

function Get-Model {
    param([object]$ProductInfo)

    if ($null -eq $ProductInfo) {
        $ProductInfo = Get-CimInstance -ClassName Win32_ComputerSystemProduct
    }

    $vendor = $ProductInfo.Vendor
    $name = $ProductInfo.Name
    $version = $ProductInfo.Version
    $vendorUpper = $vendor.ToUpper()
    $nameUpper = $name.ToUpper()
    $versionUpper = $version.ToUpper()

    if ($vendorUpper -eq "LENOVO") {
        if ($versionUpper -eq "LENOVO PRODUCT") {
            return $name
        }
        else {
            return $version
        }
    }
    elseif ($vendorUpper -eq "MICROSOFT CORPORATION") {
        if ($nameUpper -like "SURFACE*") {
            return $name
        }
        elseif (Test-IsNumeric $version) {
            return $name
        }
        else {
            return $version
        }
    }
    elseif ($vendorUpper -eq "VMWARE VIRTUAL PLATFORM") {
        return $vendor
    }
    elseif ($vendorUpper -eq "VMWARE, INC.") {
        return $name
    }
    else {
        return $name
    }

    return $version
}

function Get-UninstallEntries {
    param([scriptblock]$FilterScript)

    $registryPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $entries = foreach ($regPath in $registryPaths) {
        Get-ItemProperty ([System.IO.Path]::Combine(${regPath}, "*")) -ErrorAction SilentlyContinue
    }

    if ($FilterScript) {
        $entries = $entries | Where-Object $FilterScript
    }

    return $entries
}

function Get-ServiceEntries {
    param([string]$Name)

    try {
        return Get-Service -Name $Name -ErrorAction Stop
    }
    catch {
        return $null
    }
}

$validationEnvironment = $env:DEVICE_VALIDATION_ENV
if ([string]::IsNullOrWhiteSpace($validationEnvironment)) {
    $validationEnvironment = "prod"
}

# Only run validation tests if this is not a retry run
if (-not $isRetryRun) {

    ### Get Device Model ###
    try { 
        $productInfo = Get-CimInstance -ClassName Win32_ComputerSystemProduct
        $vendor = $productInfo.Vendor

        $isCloudPC = $false
        $cloudPcLocation = $null
        try {
            $cloudPcMetadata = Invoke-RestMethod -Headers @{"Metadata" = "true" } -Method Get -Uri "http://169.254.169.254/metadata/instance/compute?api-version=2021-11-01" -TimeoutSec 3 -ErrorAction Stop
            $cloudPcCompute = if ($cloudPcMetadata -and $cloudPcMetadata.compute) { $cloudPcMetadata.compute } else { $cloudPcMetadata }
            $metadataPublisher = $cloudPcCompute.publisher
            $metadataOffer = $cloudPcCompute.offer
            $metadataSku = $cloudPcCompute.sku
            $metadataPlanProduct = $cloudPcCompute.plan.product

            $publisherMatch = $metadataPublisher -and ($metadataPublisher.ToLower() -eq "microsoftwindowsdesktop")
            $offerMatch = $metadataOffer -and ($metadataOffer -match "windows-365|cloudpc")
            $skuMatch = $metadataSku -and ($metadataSku -match "windows-365|cloudpc")
            $planMatch = $metadataPlanProduct -and ($metadataPlanProduct -match "windows-365|cloudpc")

            if ($publisherMatch -or $offerMatch -or $skuMatch -or $planMatch) {
                $isCloudPC = $true
                if ($cloudPcCompute.location) {
                    $cloudPcLocation = $cloudPcCompute.location
                }
                Add-Info "Cloud PC detected via instance metadata (publisher: $metadataPublisher; offer: $metadataOffer; sku: $metadataSku)."
            }
            elseif ($metadataPublisher -or $metadataOffer -or $metadataSku) {
                Add-Info "Instance metadata reachable but does not indicate Cloud PC (publisher: $metadataPublisher; offer: $metadataOffer; sku: $metadataSku)."
            }
        }
        catch {
            Add-Info "Cloud PC metadata not available; attempting registry-based detection."
        }

        if (-not $isCloudPC) {
            $cloudPcRegistryKeys = @(
                "HKLM:\SOFTWARE\Microsoft\Windows 365",
                "HKLM:\SOFTWARE\Microsoft\CloudPC"
            )
            foreach ($regKey in $cloudPcRegistryKeys) {
                if (Test-Path $regKey) {
                    $isCloudPC = $true
                    Add-Info "Cloud PC detected via registry key: $regKey"
                    break
                }
            }
        }

        $model = Get-Model -ProductInfo $productInfo
        if ($isCloudPC) {
            $model = "Cloud PC"
        }
        LogWrite "Model: $model"
        if ($cloudPcLocation) {
            LogWrite "Cloud PC Location: $cloudPcLocation"
        }
    } 
    catch {
        $model = "Unknown"
        $vendor = "Unknown"
        $isCloudPC = $false
        $cloudPcLocation = $null
        LogWrite "Error retrieving device model: $($_.Exception.Message)"
    }

    $virtualMachineModels = @(
        "Virtual Machine",
        "Microsoft Corporation Hyper-V UEFI Release *"
    )

    $isVirtualMachine = $false
    foreach ($pattern in $virtualMachineModels) {
        if ($model -like $pattern) {
            $isVirtualMachine = $true
            break
        }
    }

    if ($isCloudPC) {
        $isVirtualMachine = $false
    }

    Remove-Variable -Name passCount, failCount -ErrorAction SilentlyContinue
    $failCount = 0
    $passCount = 0

    $error.clear()
    logwrite "--- Starting $scriptname $scriptver ---"

    #logwrite "=== Gather device info ==="

    if ($null -ne $env:COMPUTERNAME) {
        LogWrite "Hostname: $env:COMPUTERNAME"
    } 
    else {
        LogWrite "Device Name not found."
    }

    if ($null -ne $env:USERNAME) {
        LogWrite "Device owner: $env:USERNAME"
    }
    else {
        LogWrite "Device owner not found."
    }

    # Get full OS version
    try {
        $osInfo = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
        $fullOSVersion = "$($osInfo.CurrentMajorVersionNumber).$($osInfo.CurrentMinorVersionNumber).$($osInfo.CurrentBuildNumber).$($osInfo.UBR)"
        LogWrite "OS Version: $fullOSVersion"
    }
    catch {
        LogWrite "OS Version: Unable to retrieve"
    }

    # Get OS install date
    try {
        $installDate = $null
    
        # Method 1: Try CIM
        try {
            $osInstall = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
            if ($osInstall -and $osInstall.InstallDate) {
                $installDate = $osInstall.InstallDate
                LogWrite "OS Install Date: $($installDate.ToString('yyyy-MM-dd'))"
            }
        }
        catch {
            # CIM failed, continue to registry methods
        }

        #Method 2: If CIM failed, try registry methods
        if ($null -eq $installDate) {
            $osInfo = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue
        
            # Try InstallTime first
            if ($osInfo.PSObject.Properties.Name -contains "InstallTime" -and $osInfo.InstallTime -and $osInfo.InstallTime -ne 0) {
                try {
                    $installDate = [DateTime]::FromFileTimeUtc([int64]$osInfo.InstallTime).ToLocalTime()
                    LogWrite "OS Install Date: $($installDate.ToString('yyyy-MM-dd')) (from InstallTime)"
                }
                catch {
                    $installDate = $null
                }
            }
        
            # Fallback to InstallDate if InstallTime not available or failed
            if ($null -eq $installDate -and $osInfo.PSObject.Properties.Name -contains "InstallDate" -and $osInfo.InstallDate -and $osInfo.InstallDate -ne 0) {
                try {
                    $installDate = ([DateTime]'1/1/1970').AddSeconds([int64]$osInfo.InstallDate)
                    LogWrite "OS Install Date: $($installDate.ToString('yyyy-MM-dd')) (from InstallDate - may be build date)"
                }
                catch {
                    # InstallDate conversion failed
                    $installDate = $null
                }
            }
        }

        if ($null -eq $installDate) {
            LogWrite "OS Install Date: Unable to retrieve from any method"
        }
    }
    catch {
        LogWrite "OS Install Date: Error occurred - $($_.Exception.Message)"
    }

    # Get last boot time
    try {
        $lastBootTime = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
        $formattedBootTime = $lastBootTime.ToString("yyyy-MM-dd HH:mm:ss")
        LogWrite "Last Boot Time: $formattedBootTime"
    }
    catch {
        LogWrite "Last Boot Time: Unable to retrieve"
    }

    add-info "Checking device domain status..."
    try {
        $dsregStatus = dsregcmd /status
        $domainName = "Unknown"

        if ($dsregStatus -match "AzureAdJoined\s+:\s+YES") {
            $tenantNameLine = $dsregStatus | Where-Object { $_ -match "TenantName" }
            if ($tenantNameLine) {
                $domainName = ($tenantNameLine -split ':', 2)[1].Trim()
                logwrite "Domain: $domainName"
            }
        }
        if ($domainName -eq "CiscoITStage") {
            $validationEnvironment = "stage"
        }
        elseif ($domainName -eq "Cisco") {
            $validationEnvironment = "prod"
        }

        $certificateExpiryDays = if ($validationEnvironment -match "stage|staging|test") { 7 } else { 30 }
    }
    catch {
        logwrite "Failed to get domain info using dsregcmd. Error: $($_.Exception.Message)"
        logwrite "Domain: Unknown"
    }

    #  Start test steps

    #logwrite "=== Check Windows Version ==="
    $checkWindowsVersion = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").DisplayVersion

    if ($checkWindowsVersion -eq $windowsVersion) {
        Add-Pass "Windows version correct: $checkWindowsVersion"
    }
    else {
        Add-Fail "Windows version incorrect: $checkWindowsVersion"    
    }

    #logwrite "=== BitLocker Status ==="
    if ($isCloudPC) {
        Add-Info "Disk Encryption check skipped - Test not applicable for a Cloud PC ('$model')."
    }
    else {
        $bitLockerVolumes = Get-BitLockerVolume -ErrorAction SilentlyContinue
        if ($bitLockerVolumes) {
            $volumeIndex = 0
            $allValid = $true
        
            foreach ($volume in $bitLockerVolumes) {
                $volumeIndex++
                $volumeLabel = try { $volume.MountPoint.TrimEnd('\') } catch { "Volume $volumeIndex" }
            
                if ($volume.EncryptionPercentage -ne 100 -or $volume.EncryptionMethod -ne [Microsoft.BitLocker.Structures.BitLockerVolumeEncryptionMethodOnGet]::XtsAes256 -or $volume.ProtectionStatus -ne [Microsoft.BitLocker.Structures.BitLockerVolumeProtectionStatus]::On) {
                    if ($volume.VolumeStatus -eq [Microsoft.BitLocker.Structures.BitLockerVolumeStatus]::EncryptionInProgress) {
                        Add-Pass "$volumeLabel BitLocker encryption in progress ($($volume.EncryptionPercentage)% complete)"
                    }
                    else {
                        $allValid = $false
                        $failureReasons = @()
                        if ($volume.EncryptionPercentage -ne 100) {
                            $failureReasons += "not fully encrypted ($($volume.EncryptionPercentage)%)"
                        }
                        if ($volume.EncryptionMethod -ne "XtsAes256") {
                            $failureReasons += "incorrect encryption method ($($volume.EncryptionMethod))"
                        }
                        if ($volume.ProtectionStatus -ne "On") {
                            $failureReasons += "protection not enabled ($($volume.ProtectionStatus))"
                        }
                        $reasonText = $failureReasons -join ", "
                        Add-Fail "$volumeLabel BitLocker validation failed: $reasonText"
                    }
                }
                else {
                    Add-Pass "$volumeLabel BitLocker validation passed"
                }
            }
            if ($allValid) {
                Add-Pass "All BitLocker volumes are properly configured"
            }
        }
        else {
            Add-Fail "No BitLocker volumes found or unable to retrieve BitLocker status"
        }
    }

    #logwrite "=== Check Microsoft 365 ==="
    $office365Installed = $false

    if ($sysResetExists -eq $true) {
        Add-Info "Sys Reset detected. Skipping Microsoft 365 installation check as it may not be present in this environment."
    } 
    else {
        $office365Check = Get-UninstallEntries -FilterScript { 
            ($_.DisplayName -like "*Microsoft 365*" -and $_.DisplayName -like "*Apps*") -or
            ($_.DisplayName -like "*Office 365*") -or
            ($_.DisplayName -like "*O365*") -or
            ($_.DisplayName -like "*Microsoft Office 365*")
        }

        if ($null -ne $office365Check) {
            $office365Installed = $true
        }

        # If not found in registry, check for Office executable files
        if (-not $office365Installed) {
            $officeExes = @(
                [System.IO.Path]::Combine(${env:ProgramFiles}, "Microsoft Office", "root", "Office16", "WINWORD.EXE"),
                [System.IO.Path]::Combine(${env:ProgramFiles(x86)}, "Microsoft Office", "root", "Office16", "WINWORD.EXE"),
                [System.IO.Path]::Combine(${env:ProgramFiles}, "Microsoft Office", "Office16", "WINWORD.EXE"),
                [System.IO.Path]::Combine(${env:ProgramFiles(x86)}, "Microsoft Office", "Office16", "WINWORD.EXE")
            )
        

            foreach ($exePath in $officeExes) {
                if (Test-Path $exePath) {
                    $office365Installed = $true
                    break
                }
            }
        }

        if ($office365Installed) {
            Add-Pass "Microsoft 365 Apps for enterprise is installed."
        } 
        else {
            Add-Fail "Microsoft 365 Apps for enterprise is not installed."
        }
    }

    #logwrite "=== Word Automation ==="

    if (Get-UninstallEntries -FilterScript { $_.DisplayName -match "Word|Office|Microsoft 365" }) {
        Add-Pass "Word installed "
        try {
            $word = $null
            $doc = $null
            $word = New-Object -ComObject Word.Application
            $word.Visible = $false
            $doc = $word.Documents.Add()
            $doc.Content.Text = "Automated test content"
            $docTimeDate = Get-Date -Format "yyyyMMdd_HHmmss"
            $wordDocPath = [System.IO.Path]::Combine(${env:USERPROFILE}, "Documents", "AutomatedTest_${docTimeDate}.docx")
        
            try {
                $doc.SaveAs2($wordDocPath, 16)
                Start-Sleep -Milliseconds 500
                $doc.Close([ref]$false)
                $word.Quit()
                [System.Runtime.Interopservices.Marshal]::ReleaseComObject($doc) | Out-Null
                [System.Runtime.Interopservices.Marshal]::ReleaseComObject($word) | Out-Null
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
            } 
            catch {
                Add-Fail "Failed to save or close Word document: $($_.Exception.Message)"
                if ($doc) { 
                    try { 
                        $doc.Close([ref]$false) 
                        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($doc) | Out-Null
                    } 
                    catch {} 
                }
                if ($word) { 
                    try { 
                        $word.Quit() 
                        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($word) | Out-Null
                    } 
                    catch {} 
                }
            }
        
            Start-Sleep -Milliseconds 1000
        
            if (Test-Path $wordDocPath) {
                Add-Pass "Word document created and saved at $wordDocPath "
            } 
            else {
                Add-Fail "Failed to save Word document at $wordDocPath "
            }
        } 
        catch {
            Add-Fail "Word automation failed: $($_.Exception.Message)"
            if ($doc) { 
                try { 
                    $doc.Close([ref]$false)
                    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($doc) | Out-Null
                } 
                catch {} 
            }
            if ($word) { 
                try { 
                    $word.Quit()
                    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($word) | Out-Null
                } 
                catch {} 
            }
        }
    }
    else {
        Add-Fail "Word is NOT installed "   
    }


    # logwrite "=== OneDrive File Sync ==="
    try {
        $oneDriveProcess = Get-process -Name OneDrive -ErrorAction Stop

        if ($oneDriveProcess) {
            Add-Pass "OneDrive is running "
        
            if (Test-Path ${wordDocPath}) {
                $dst = [System.IO.Path]::Combine(${env:OneDrive}, "AutomatedTest.txt")
                Copy-Item ${wordDocPath} ${dst} -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 5
                
                if (Test-Path ${dst}) {
                    Add-Pass "Word document copied to OneDrive folder."
                    Remove-item ${dst} -Force -ErrorAction SilentlyContinue
                    Remove-item ${wordDocPath} -Force -ErrorAction SilentlyContinue
                } 
                else {
                    Add-Fail "Failed to copy file to OneDrive."
                }
            } 
            else {
                Add-Fail "Word document not found - cannot test OneDrive sync."
                if (Test-Path ${wordDocPath}) {
                    Remove-item ${wordDocPath} -Force -ErrorAction SilentlyContinue
                }
            }
        }
        else {
            Add-Fail "OneDrive process not found."
        }
    }
    catch {
        Add-Fail "OneDrive process not found or not running."
    }

    #logwrite "=== Druva Check ==="

    $druvaCheck = Get-UninstallEntries -FilterScript { $_.DisplayName -like "Druva inSync*" } | Select-Object DisplayName, DisplayVersion | Select-Object -First 1

    $druvaLogBasePath = [System.IO.Path]::Combine(${env:ProgramData}, "Druva", "inSync4", "users")
    $searchString = "Stats for this cycle"

    if ($druvaCheck -and [System.Version] $druvaCheck.DisplayVersion -ge [System.Version] $druvaVersion) {
        Add-Pass "Druva is installed with the correct version ($($druvaCheck.DisplayVersion))"

        $druvaService = Get-ServiceEntries -Name "inSyncCPHService" -ErrorAction SilentlyContinue
        if ($druvaService) {
            Add-Pass "Druva Service is running"

            if (Test-Path $druvaLogBasePath) {
                # Find all log files across all user subdirectories
                $logFiles = Get-ChildItem -Path $druvaLogBasePath -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.DirectoryName -match '\\logs$' -and $_.Extension -match '\.(txt|log)' }

                if ($logFiles) {
                    $stringFound = $logFiles | Select-String -Pattern $searchString -SimpleMatch
                    if ($null -ne $stringFound) {
                        Add-Pass "Druva backup complete"
                    }
                    else {
                        Add-Fail "Druva backup not found in logs"
                    }
                }
                else {
                    Add-Fail "No Druva log files found"
                }
            }
            else {
                Add-Fail "Druva log folder not found at: $druvaLogBasePath"
            }
        }
        else {
            Add-Fail "Druva Service is not running"
        }
    }
    else {
        Add-Fail "Druva is not installed."
    }

    #write-host "=== WebEx Install Check ==="

    # Determine the required Webex version based on whether it's a Cloud PC
    $currentRequiredWebexVersion = $webexVersion
    if ($isCloudPC) {
        Add-Info "Device is a Cloud PC ('$model'). Using Cloud PC-specific WebEx version check."
        $currentRequiredWebexVersion = $webexVersionVM
    }
    else {
        Add-Info "Device is a physical machine. Using standard WebEx version check."
    }

    try {
        # Check registry for Webex installation
        $webexCheck = @(Get-UninstallEntries -FilterScript { $_.DisplayName -like "*Webex*" -or $_.DisplayName -like "*Cisco Spark*" })
    
        if ($webexCheck.Count -gt 0) {
            $installedWebexVersions = $webexCheck | Where-Object { $_.DisplayVersion } | Select-Object -ExpandProperty DisplayVersion
            $installedWebexVersion = $installedWebexVersions | Where-Object { $_ -and $_.Trim() -ne "" }
            if ($installedWebexVersion -and $installedWebexVersion.Count -gt 0) {
                try {
                    $installedWebexVersionObj = $null
                    foreach ($versionString in $installedWebexVersion) {
                        $parsedVersion = $null
                        if ([System.Version]::TryParse($versionString.Trim(), [ref]$parsedVersion)) {
                            if ($null -eq $installedWebexVersionObj -or $parsedVersion -gt $installedWebexVersionObj) {
                                $installedWebexVersionObj = $parsedVersion
                            }
                        }
                    }
                    if ($null -eq $installedWebexVersionObj) {
                        throw "No valid Webex version found in registry."
                    }
                    $requiredWebexVersionObj = [System.Version]$currentRequiredWebexVersion
                    if ($installedWebexVersionObj -eq $requiredWebexVersionObj) {
                        Add-Pass "WebEx is installed with the correct version ($installedWebexVersionObj) for this device type (required: $currentRequiredWebexVersion)."
                    }
                    elseif ($installedWebexVersionObj -gt $requiredWebexVersionObj) {
                        Add-Pass "WebEx is installed with a newer version ($installedWebexVersionObj) than required ($currentRequiredWebexVersion) for this device type."
                    }
                    else {
                        Add-Fail "WebEx is installed with a version ($installedWebexVersionObj) that is older than required ($currentRequiredWebexVersion) for this device type."
                    }
                }
                catch {
                    Add-Fail "Error comparing Webex versions: $($_.Exception.Message)"
                }
            }
            else {
                Add-Fail "WebEx is installed but version could not be determined from registry."
            }
        }
        else {
            Add-Fail "WebEx is not installed."
        }
    }
    catch {
        Add-Fail "Error checking Webex installation: $($_.Exception.Message)"
    }

    #logwrite "=== Edge Test ==="

    if (Test-Path ([System.IO.Path]::Combine(${env:ProgramFiles(x86)}, "Microsoft", "Edge", "Application", "msedge.exe"))) {
        Add-Pass "Microsoft Edge is installed."
    } 
    else {
        Add-Fail "Microsoft Edge is NOT installed."
    }

    # logwrite "=== Duo Desktop Check ==="

    try {
        $duoCheck = @(Get-UninstallEntries -FilterScript { ($_.DisplayName -eq "Duo Desktop") })
        if ($duoCheck.count -gt 0) {
            $duoVersion = $duoCheck.DisplayVersion
            if ($null -ne $duoVersion) {
                try {
                    $installedDuoVersion = [version]$duoVersion
                    $requiredDuoVersion = [version]$duoDesktopVersion
                    if ($installedDuoVersion -eq $requiredDuoVersion) {
                        Add-Pass "Duo Desktop is installed with the correct version ($installedDuoVersion)."
                    }
                    elseif ($installedDuoVersion -gt $requiredDuoVersion) {
                        Add-Pass "Installed Duo Desktop version is newer than required (installed: $installedDuoVersion, required: $duoDesktopVersion)."
                    }
                    else {
                        Add-Fail "Duo Desktop version is incorrect (installed: $installedDuoVersion, required: $duoDesktopVersion)."
                    }
                } 
                catch {
                    Add-Fail "Error comparing Duo Desktop versions: $($_.Exception.Message)"
                }
            } 
            else {
                Add-Fail "Could not determine installed Duo Desktop version."
            }

            try {
                $duoService = Get-Service -Name "Duo Crypto Service" -ErrorAction SilentlyContinue
                if ($null -ne $duoService) {
                    if ($duoService.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
                        Add-Pass "Duo Crypto Service is running."
                    }
                    else {
                        Add-Fail "Duo Crypto Service is installed but not running. Status: $($duoService.Status)"
                    }
                } 
                else {
                    Add-Fail "Duo Crypto Service is not running or not installed."
                }
            } 
            catch {
                Add-Fail "Error checking Duo Crypto Service: $($_.Exception.Message)"
            }
        } 
        else {
            Add-Fail "Duo Desktop is not installed."
        }
    } 
    catch {
        Add-Fail "Error checking Duo Desktop: $($_.Exception.Message)"
    }

    # logwrite "=== Lenovo Vantage Check ==="

    if ($productInfo.Vendor -eq "Lenovo") {
        if ($sysResetExists -eq $true) {
            Add-Info "Lenovo device detected, skipping Lenovo Vantage check due to SysReset."
        }
        else {
            Add-Info "Lenovo device detected, checking for Lenovo Vantage."
            $vantagePackage = Get-AppxPackage -AllUsers -Name "*LenovoCommercialVantage*" -ErrorAction SilentlyContinue

            if ($null -eq $vantagePackage) {
                Add-Fail "Lenovo Vantage not found."
            } 
            else {
                Add-Pass "Found Lenovo Vantage ($($vantagePackage.Version))"
            }
        }
    }
    else {
        Add-Info "Not a Lenovo device, skipping Lenovo Vantage check."
    }

    # logwrite "=== Device Network cert check ==="

    try {
        # First check if certificate exists at all
        $deviceCertAll = Get-ChildItem Cert:\LocalMachine\My\ | Where-Object { $_.Subject -like "CN=CiscoDeviceNetworkAccess*" } | Select-Object -First 1
        if ($null -ne $deviceCertAll) {
            Add-Pass "Cisco network Device certificate exists."
            $deviceCertExpiring = Get-ChildItem Cert:\LocalMachine\My\ | Where-Object { $_.Subject -like "CN=CiscoDeviceNetworkAccess*" -and $_.NotAfter -le (Get-Date).AddDays($certificateExpiryDays) } | Select-Object -First 1
            if ($null -ne $deviceCertExpiring) {
                $deviceCertExpiry = $deviceCertExpiring.NotAfter.ToString("yyyy-MM-dd")
                Add-Pass "Cisco network Device certificate expires within $certificateExpiryDays days (expires: $deviceCertExpiry)"
            }
            else {
                $deviceCertExpiry = $deviceCertAll.NotAfter.ToString("yyyy-MM-dd")
                Add-Fail "Cisco network Device certificate expires beyond $certificateExpiryDays days (expires: $deviceCertExpiry)"
            }
        } 
        else {
            Add-Fail "Cisco network Device certificate does not exist."
        }
    }
    catch {
        Add-Fail "Error checking Cisco network Device certificate: $($_.Exception.Message)"
    }

    # logwrite "=== User Network cert check ==="

    try {
        $userCertAll = Get-ChildItem Cert:\CurrentUser\My\ | Where-Object { $_.Subject -like "CN=CiscoUserNetworkAccess*" } | Select-Object -First 1
        if ($null -ne $userCertAll) {
            Add-Pass "Cisco network user certificate exists."
            $userCertExpiring = Get-ChildItem Cert:\CurrentUser\My\ | Where-Object { $_.Subject -like "CN=CiscoUserNetworkAccess*" -and $_.NotAfter -le (Get-Date).AddDays(30) } | Select-Object -First 1
            if ($null -ne $userCertExpiring) {
                $userCertExpiry = $userCertExpiring.NotAfter.ToString("yyyy-MM-dd")
                Add-Pass "Cisco network user certificate expires within 30 days (expires: $userCertExpiry)"
            }
            else {
                $userCertExpiry = $userCertAll.NotAfter.ToString("yyyy-MM-dd")
                Add-Fail "Cisco network user certificate expires beyond 30 days (expires: $userCertExpiry)"
            }
        }
        else {
            Add-Fail "Cisco network user certificate does not exist."
        }
    }
    catch {
        Add-Fail "Error occurred while checking Cisco network user certificate: $_"
    }

    # logwrite "=== Check Windows Activation ==="
    try {
        $windowsActivation = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "PartialProductKey <> null and LicenseStatus=1 and Description like 'Windows%Operating System%'"
        if ($windowsActivation.LicenseStatus -eq 1) {
            Add-Pass "Windows is activated"
        }
        else {
            Add-Fail "Windows is not activated"
        }
    }
    catch {
        Add-Fail "Error checking Windows activation: $($_.Exception.Message)"
    }

    # logwrite "=== Check Setup Assistant log ==="
    $setupAssistantPath = [System.IO.Path]::Combine("${env:SystemDrive}\", "IT_Logs", "Cisco.Windows.App.Setup.Assistant.log")

    if (Test-Path ${setupAssistantPath}) {
        Add-Pass "Setup Assistant log exists."
        $setupAssistantErrors = Select-String -Path $setupAssistantPath -Pattern "error" -CaseSensitive:$false

        if ($setupAssistantErrors) {
            $errorLines = $setupAssistantErrors | ForEach-Object { $_.Line }
            $allErrors = $errorLines -join "; "
            Add-Info "Errors found in Setup Assistant log: $allErrors"
        } 
        else {
            Add-Pass "No issues found in Setup Assistant log."
        }
    }
    else {
        Add-Info "Log file not found at path: $setupAssistantPath"
    }

    # logwrite "=== Microsoft Defender for Endpoint (MDE) + Cisco Secure Endpoint (CSE) Check ==="
    # If MDE is present and healthy, CSE checks are skipped.
    # If MDE is absent or not running fall through to the standard CSE checks.

    $mdeHealthy = $false

    if ($validationEnvironment -match "stage|staging|test") {
        Add-Info "MDE/CSE check skipped - Test not applicable for Stage environment."
    }
    else {
        try {
            $mdeService = Get-ServiceEntries -Name "Sense"
            if ($mdeService -and $mdeService.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
                # MDE service is running - verify SENSE is onboarded via registry
                $mdeOnboarded = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status" -ErrorAction SilentlyContinue
                if ($mdeOnboarded -and $mdeOnboarded.OnboardingState -eq 1) {
                    Add-Pass "Microsoft Defender for Endpoint (MDE) service is running and device is onboarded."
                    $mdeHealthy = $true
                }
                else {
                    Add-Info "MDE service is running but device does not appear to be onboarded. Falling back to CSE checks."
                }
            }
            else {
                Add-Info "Microsoft Defender for Endpoint (MDE) service (Sense) is not running or not installed. Falling back to CSE checks."
            }
        }
        catch {
            Add-Info "Error checking MDE service: $($_.Exception.Message). Falling back to CSE checks."
        }

        if (-not $mdeHealthy) {
            # logwrite "=== Cisco Secure Endpoint Check (CSE) ==="
            try {
                $cse = Get-UninstallEntries -FilterScript { $_.DisplayName -like "Cisco Secure Endpoint*" }
                if ($null -ne $cse) {
                    $cseVersion = $cse.DisplayVersion
                    if ($null -ne $cseVersion) {
                        try {
                            $installedCSEVersion = [version]$cseVersion
                            $requiredCSEVersion = [version]$secureEndpointVersion
                            if ($installedCSEVersion -eq $requiredCSEVersion) {
                                Add-Pass "Cisco Secure Endpoint is installed with the correct version ($cseVersion)."
                            } 
                            elseif ($installedCSEVersion -gt $requiredCSEVersion) {
                                Add-Pass "Installed Cisco Secure Endpoint version is newer than required (installed: $cseVersion, required: $secureEndpointVersion)."
                            } 
                            else {
                                Add-Fail "Cisco Secure Endpoint version is incorrect (installed: $cseVersion, required: $secureEndpointVersion)."
                            }
                        }
                        catch {
                            Add-Fail "Error comparing Cisco Secure Endpoint versions: $($_.Exception.Message)"
                        }
                    }
                    else {
                        Add-Fail "Could not determine installed Cisco Secure Endpoint version."
                    }

                    # CSE Health Check - Verify service is running
                    try {
                        $cseService = Get-Service | Where-Object { $_.DisplayName -like "Cisco Secure Endpoint*" }
                        if ($cseService) {
                            if ($cseService.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
                                Add-Pass "Cisco Secure Endpoint service is running."
                            } 
                            else {
                                Add-Fail "Cisco Secure Endpoint service is installed but not running. Status: $($cseService.Status)"
                            }
                        } 
                        else {
                            Add-Fail "Cisco Secure Endpoint service not found."
                        }
                    }
                    catch {
                        Add-Fail "Error checking Cisco Secure Endpoint service: $($_.Exception.Message)"
                    }
                }
                else {
                    Add-Fail "Cisco Secure Endpoint is not installed."
                }
            }
            catch {
                Add-Fail "Error checking Cisco Secure Endpoint: $($_.Exception.Message)"
            }
        }
    }

    # logwrite "=== Cisco Secure Client Check ===" 

    $allRequiredComponents = @(
        "Cisco Secure Client - Cloud Management",
        "Cisco Secure Client - AnyConnect VPN",
        "Cisco Secure Client - Zero Trust Access",
        "Cisco Secure Client - Umbrella",
        "Cisco Secure Client - Network Visibility Module",
        "Cisco Secure Client - Diagnostics and Reporting Tool"
    )

    $finalRequiredComponents = $allRequiredComponents

    $installedComponents = Get-UninstallEntries -FilterScript { $_.DisplayName -like "*Cisco Secure Client*" } | select-object -ExpandProperty "DisplayName"

    $missingComponents = Compare-Object -ReferenceObject $finalRequiredComponents -DifferenceObject $installedComponents | Where-Object { $_.SideIndicator -eq "<=" } | Select-Object -ExpandProperty InputObject

    if ($missingComponents.Count -eq 0) {
        Add-Pass "All required Cisco Secure Client components are installed."
    
        $service = Get-ServiceEntries -Name "csc_vpnagent"
        if ($service) {
            Add-Pass "Cisco Secure Client Service - AnyConnect VPN Agent service is running."
        } 
        else {
            Add-Fail "Cisco Secure Client Service - AnyConnect VPN Agent service is not running."
        }
    }
    else {
        $missingList = $missingComponents -join ", "
        Add-Fail  "Missing required components: $missingList"
    }

    if (-not $isRetryRun) {
        logwrite "=== Results ==="
        logwrite "Passed: $passCount"
        logwrite "Failed: $failCount"
    }

}

#Upload to S3

$deviceName = $env:COMPUTERNAME
$apiUrl = $env:DEVICE_VALIDATION_API_URL
$clientId = $env:DEVICE_VALIDATION_CLIENT_ID
$clientSecret = $env:DEVICE_VALIDATION_CLIENT_SECRET
$tokenEndpoint = $env:DEVICE_VALIDATION_TOKEN_ENDPOINT

$tokenResponse = Invoke-RestMethod -Uri $tokenEndpoint `
    -Method Post `
    -Body @{
    grant_type = "client_credentials"
    client_id = $clientId
    client_secret = $clientSecret
    scope = ""
}

$headers = @{
    "Authorization" = "Bearer $($tokenResponse.access_token)"
    "User-Agent" = "PowerShell/7.0"
    "Accept" = "*/*"
}

try {
    LogWrite "Requesting presigned URL..."
    $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers
    
    $completeUrl = $response.uploadUrl
    LogWrite "Success. Got URL"
    
    if ([string]::IsNullOrEmpty($completeUrl)) {
        throw "Presigned URL is null or empty. API Response: $($response | ConvertTo-Json)"
    }
    
    logwrite "Uploading log to S3..."
    Invoke-WebRequest -Uri $completeUrl -Method Put -InFile $LogFile -UseBasicParsing
    logwrite "Upload to S3 complete."
    
    # Clear retry counter on successful upload
    Remove-ItemProperty -Path $deviceValidationKey -Name "RetryCount" -ErrorAction SilentlyContinue
    
    # Write a registry value to trigger one-time Intune sync on next check-in

    $oneTimePushKey = 'HKLM:\Software\Cisco Internal\Intune\OneTimePush'
    $pathsToEnsure = @(
        'HKLM:\Software\Cisco Internal',
        'HKLM:\Software\Cisco Internal\Intune',
        $oneTimePushKey
    )
    foreach ($p in $pathsToEnsure) {
        if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
    }
    
    $dateTimeValue = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    logwrite "Writing OneTimePush timestamp to registry: ${dateTimeValue}"
    New-ItemProperty -Path ${oneTimePushKey} -Name "${scriptname}" -Value ${dateTimeValue} -PropertyType String -Force | Out-Null
    
    # Clear the validation timer from registry
    try {
        Remove-ItemProperty -Path $deviceValidationKey -Name "StartTime" -ErrorAction SilentlyContinue
        logwrite "Cleared validation timer from registry."
    }
    catch {
        logwrite "Failed to clear validation timer: $_"
    }
    
    $taskName = "Cisco-DeviceValidation-Task"
    try {
        logwrite "Validation complete. Scheduling cleanup after script exits."
        
        # Create a cleanup script that will run after this script exits
        $cleanupScript = @"
Start-Sleep -Seconds 5

# Delete the scheduled task only if it exists
`$taskExists = schtasks.exe /Query /TN '$taskName' 2>`$null
if (`$LASTEXITCODE -eq 0) 
{
    schtasks.exe /Delete /TN '$taskName' /F 2>&1 | Out-File ([System.IO.Path]::Combine(`$env:SystemDrive, 'IT_Logs', 'CiscoIT_deviceValidation_TaskCleanup.log'))
} 
else 
{
    'Scheduled task not found - nothing to delete' | Out-File ([System.IO.Path]::Combine(`$env:SystemDrive, 'IT_Logs', 'CiscoIT_deviceValidation_TaskCleanup.log'))
}

# Remove the script from ProgramData
if (Test-Path ([System.IO.Path]::Combine(`$env:ProgramData, 'CiscoIT', 'DeviceValidation'))) 
{
    Remove-Item -Path ([System.IO.Path]::Combine(`$env:ProgramData, 'CiscoIT', 'DeviceValidation')) -Recurse -Force -ErrorAction SilentlyContinue
    Add-Content ([System.IO.Path]::Combine(`$env:SystemDrive, 'IT_Logs', 'CiscoIT_deviceValidation_TaskCleanup.log')) -Value 'Script cleaned up from ProgramData'
}
"@
        
        # Save the cleanup script
        $cleanupScriptPath = [System.IO.Path]::Combine(${env:TEMP}, "CleanupValidationTask.ps1")
        $cleanupScript | Out-File -FilePath ${cleanupScriptPath} -Encoding UTF8 -Force
        
        # Start the cleanup script in a separate process that will run after this script exits
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"${cleanupScriptPath}`"" -WindowStyle Hidden
        
        logwrite "Cleanup scheduled. A background process will delete the task and script in 5 seconds."
    } 
    catch {
        logwrite "Failed to schedule task deletion. Error: $($_.Exception.Message)"
        logwrite "Task may need to be manually deleted."
    }

    logwrite "Script finished successfully."
    exit 0
} 
catch {
    LogWrite "Upload failed: $($_.Exception.Message)"
    
    # Incremental retry counter
    $currentRetries = 0
    $retryCount = Get-ItemProperty -Path $deviceValidationKey -Name "RetryCount" -ErrorAction SilentlyContinue
    if ($retryCount) {
        $currentRetries = [int]$retryCount.RetryCount
    }
    $currentRetries++
    
    if ($currentRetries -le $maxUploadRetries) {
        # Save retry count and keep task for retry
        New-ItemProperty -Path $deviceValidationKey -Name "RetryCount" -Value $currentRetries -PropertyType DWord -Force | Out-Null
        LogWrite "Upload retry $currentRetries of $maxUploadRetries will be attempted on next task run."
        exit 1
    } 
    else {
        LogWrite "Maximum upload retries reached ($maxUploadRetries). Cleaning up and exiting."
        Remove-ItemProperty -Path $deviceValidationKey -Name "StartTime" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $deviceValidationKey -Name "RetryCount" -ErrorAction SilentlyContinue
        
        $taskExists = schtasks.exe /Query /TN $taskName 2>$null
        if ($LASTEXITCODE -eq 0) {
            schtasks.exe /Delete /TN $taskName /F | Out-Null
            LogWrite "Scheduled task deleted after max retries."
        }
        exit 1
    }
}
