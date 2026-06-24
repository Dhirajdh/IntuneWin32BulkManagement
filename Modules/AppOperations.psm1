# ==========================================
# AppOperations.psm1
# Intune Win32 Bulk Management
# ==========================================

# --------------------------------------------------
# Get Win32 Applications
# --------------------------------------------------

function Get-IntuneWin32Apps {

    try {

        Write-UILog `
            -Message "Loading Win32 applications..."

        # Use the beta REST endpoint directly so every field (displayVersion,
        # installCommandLine, fileName, etc.) is returned as a top-level key
        # in the response hashtable — no AdditionalProperties wrapper needed.
        $uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$filter=isof('microsoft.graph.win32LobApp')&`$top=999"
        $Win32Apps = Get-AllGraphPages -Uri $uri

        Write-UILog `
            -Message "$($Win32Apps.Count) Win32 apps loaded" `
            -Level SUCCESS

        return $Win32Apps

    }
    catch {

        Write-UILog `
            -Message $_.Exception.Message `
            -Level ERROR

        return @()

    }

}
# --------------------------------------------------
# Get Assignment Count
# --------------------------------------------------

function Get-AppAssignmentCount {

    param(
        [string]$AppId
    )

    try {

        $uri = "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/$AppId/assignments"
        $result = Invoke-GraphGet -Uri $uri
        return @($result.value).Count

    }
    catch {

        return 0

    }

}
# --------------------------------------------------
# Get Full Assignments
# --------------------------------------------------

function Get-AppAssignments {

    param(
        [Parameter(Mandatory)]
        [string]$AppId
    )

    try {

        $Uri =
            "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/assignments"

        $Result =
            Invoke-GraphGet `
            -Uri $Uri

        return $Result.value

    }
    catch {

        Write-UILog `
            -Message $_.Exception.Message `
            -Level ERROR

        return @()

    }

}

# --------------------------------------------------
# Helper: safe key access for REST response hashtables
# --------------------------------------------------

function Get-HT {
    param($Dict, $Key)
    try {
        if ($Dict -and $Dict.ContainsKey($Key)) { return [string]$Dict[$Key] }
    } catch { }
    return ""
}

# --------------------------------------------------
# Group name cache — avoids repeated Graph calls when
# the same group is assigned across multiple apps
# --------------------------------------------------

$Script:GroupNameCache = @{}

function Get-GroupDisplayName {
    param([string]$GroupId)
    if ([string]::IsNullOrWhiteSpace($GroupId)) { return "" }
    if ($Script:GroupNameCache.ContainsKey($GroupId)) { return $Script:GroupNameCache[$GroupId] }
    try {
        # Use Invoke-MgGraphRequest directly to suppress the UI-log side-effect on failure
        $result = Invoke-MgGraphRequest -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId`?`$select=id,displayName"
        $name = [string]$result["displayName"]
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $GroupId }
        $Script:GroupNameCache[$GroupId] = $name
        return $name
    }
    catch {
        $Script:GroupNameCache[$GroupId] = $GroupId  # cache failure too so we don't retry
        return $GroupId
    }
}

# --------------------------------------------------
# Build Grid Object
# --------------------------------------------------

function ConvertTo-AppGridObject {

    param(
        [Parameter(Mandatory)]
        [object]$App
    )

    # App is a Hashtable returned by Invoke-MgGraphRequest (via Get-AllGraphPages).
    # All Intune properties are top-level keys — no AdditionalProperties wrapper needed.

    $Version = ""

    try {
        # 1. displayVersion — the standard Intune Win32 display-version field
        $dv = Get-HT $App "displayVersion"
        if (-not [string]::IsNullOrWhiteSpace($dv)) { $Version = $dv }

        # 2. MSI productVersion
        if ([string]::IsNullOrWhiteSpace($Version)) {
            $msiInfo = $null
            try { if ($App.ContainsKey("msiInformation")) { $msiInfo = $App["msiInformation"] } } catch { }
            if ($msiInfo) {
                $pv = ""
                try { $pv = [string]$msiInfo["productVersion"] } catch {
                    try { $pv = [string]$msiInfo.productVersion } catch { }
                }
                if (-not [string]::IsNullOrWhiteSpace($pv)) { $Version = $pv }
            }
        }

        # 3. Regex parse from text candidates
        if ([string]::IsNullOrWhiteSpace($Version)) {
            $candidates = @(
                (Get-HT $App "displayName"),
                (Get-HT $App "installCommandLine"),
                (Get-HT $App "uninstallCommandLine"),
                (Get-HT $App "fileName"),
                (Get-HT $App "bundleVersion"),
                (Get-HT $App "description")
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

            foreach ($text in $candidates) {
                if ($text -match '(?<!\d)(v?\d+(?:\.\d+){1,3})(?!\d)') { $Version = $Matches[1]; break }
                if ($text -match '(?i)version\s*(v?\d+(?:\.\d+){1,3})') { $Version = $Matches[1]; break }
            }
        }
    }
    catch { $Version = "" }

    $VersionDisplay = if ([string]::IsNullOrWhiteSpace($Version)) { "-" } else { $Version }

    $AppId = Get-HT $App "id"

    # Fetch existing assignments and resolve each target to a human-readable name.
    # Results are cached in $Script:GroupNameCache so repeated group IDs cost only one API call.
    $AssignmentCount     = 0
    $AssignedGroupStr    = ""
    $AssignmentIntentStr = ""

    $intentFriendly = @{
        "required"                   = "Required"
        "available"                  = "Available"
        "uninstall"                  = "Uninstall"
        "availableWithoutEnrollment" = "Available (No Enroll)"
    }

    try {
        $uri         = "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/$AppId/assignments"
        $assignData  = Invoke-MgGraphRequest -Method GET -Uri $uri
        $assignments = @($assignData["value"])
        $AssignmentCount = $assignments.Count

        if ($AssignmentCount -gt 0) {
            $resolvedNames  = @()
            $resolvedIntents = @()

            foreach ($a in $assignments) {
                $targetType = ""
                try { $targetType = [string]$a["target"]["@odata.type"] } catch { }

                # Resolve target name
                if ($targetType -like "*groupAssignmentTarget*") {
                    $gid = ""
                    try { $gid = [string]$a["target"]["groupId"] } catch { }
                    if (-not [string]::IsNullOrWhiteSpace($gid)) {
                        $resolvedNames += Get-GroupDisplayName -GroupId $gid
                    }
                }
                elseif ($targetType -like "*allDevicesAssignmentTarget*") {
                    $resolvedNames += "All Devices"
                }
                elseif ($targetType -like "*allLicensedUsersAssignmentTarget*") {
                    $resolvedNames += "All Users"
                }

                # Collect intent
                $intentRaw = ""
                try { $intentRaw = [string]$a["intent"] } catch { }
                if (-not [string]::IsNullOrWhiteSpace($intentRaw)) {
                    $label = $intentFriendly[$intentRaw]
                    if ([string]::IsNullOrWhiteSpace($label)) { $label = $intentRaw }
                    $resolvedIntents += $label
                }
            }

            $AssignedGroupStr    = ($resolvedNames   | Where-Object { $_ } | Select-Object -Unique) -join "; "
            $AssignmentIntentStr = ($resolvedIntents | Where-Object { $_ } | Select-Object -Unique) -join " / "
        }
    }
    catch { }

    [PSCustomObject]@{
        Selected          = $false
        Id                = $AppId
        DisplayName       = Get-HT $App "displayName"
        Description       = Get-HT $App "description"
        Publisher         = Get-HT $App "publisher"
        Version           = $VersionDisplay
        FileName          = Get-HT $App "fileName"
        InstallCommand    = Get-HT $App "installCommandLine"
        UninstallCommand  = Get-HT $App "uninstallCommandLine"
        AssignmentCount   = $AssignmentCount
        Status            = if ($AssignmentCount -gt 0) { "Assigned" } else { "Not Assigned" }
        AssignedGroups    = $AssignedGroupStr
        AssignmentIntent  = $AssignmentIntentStr
    }
}

# --------------------------------------------------
# Export CSV
# --------------------------------------------------

function Export-AppsToCsv {

    param(

        [Parameter(Mandatory)]
        [array]$Apps,

        [Parameter(Mandatory)]
        [string]$Path

    )

    try {

        $Apps |
        Export-Csv `
            -Path $Path `
            -NoTypeInformation `
            -Encoding UTF8

        Write-UILog `
            -Message "Exported to $Path" `
            -Level SUCCESS

    }
    catch {

        Write-UILog `
            -Message $_.Exception.Message `
            -Level ERROR

    }

}

# --------------------------------------------------
# Backup JSON
# --------------------------------------------------

function Backup-AppsToJson {

    param(

        [Parameter(Mandatory)]
        [array]$Apps,

        [Parameter(Mandatory)]
        [string]$Path

    )

    try {

        $Apps |
        ConvertTo-Json `
            -Depth 20 |
        Set-Content `
            -Path $Path `
            -Encoding UTF8

        Write-UILog `
            -Message "Backup created: $Path" `
            -Level SUCCESS

    }
    catch {

        Write-UILog `
            -Message $_.Exception.Message `
            -Level ERROR

    }

}

# --------------------------------------------------
# Delete Single App
# --------------------------------------------------

function Remove-IntuneWin32App {

    param(
        [string]$AppId
    )

    try {

        Remove-MgDeviceAppManagementMobileApp `
            -MobileAppId $AppId

        Write-UILog `
            -Message "Deleted $AppId" `
            -Level SUCCESS

        return $true

    }
    catch {

        Write-UILog `
            -Message $_.Exception.Message `
            -Level ERROR

        return $false

    }

}

# --------------------------------------------------
# Bulk Delete
# --------------------------------------------------

function Remove-SelectedApps {

    param(
        [array]$Apps,
        [object]$ProgressBar,
        [object]$ProgressLabel
    )

    $Total =
        $Apps.Count

    $Current = 0

    foreach ($App in $Apps) {

        $Current++

        $Percent =
            [math]::Round(
                ($Current / $Total) * 100,
                0
            )

		$ProgressBar.Dispatcher.Invoke({

			$ProgressBar.Value =
				$Percent

		})

		$ProgressLabel.Dispatcher.Invoke({

			$ProgressLabel.Text =
				"$Current of $Total ($Percent%)"

		})
		
[System.Windows.Forms.Application]::DoEvents()


Write-UILog `
    -Message "Deleting $($App.DisplayName)"
	

        Remove-IntuneWin32App `
            -AppId $App.Id

    }

    $ProgressBar.Value = 100
    $ProgressLabel.Text = "Completed"

    return $true
}
# --------------------------------------------------
# Search Filter
# --------------------------------------------------

function Search-Apps {

    param(

        [Parameter(Mandatory)]
        [array]$Apps,

        [string]$SearchText

    )

    if ([string]::IsNullOrWhiteSpace(
        $SearchText
    )) {

        return $Apps

    }

    return (
        $Apps |
        Where-Object {

            $_.DisplayName `
                -like "*$SearchText*" `
            -or
            $_.Publisher `
                -like "*$SearchText*"

        }
    )

}

# --------------------------------------------------
# Create Grid Collection
# --------------------------------------------------

function Get-AppGridData {

    # Clear the cache on each refresh so renamed groups are picked up
    $Script:GroupNameCache = @{}

    $Apps =
        Get-IntuneWin32Apps

    $GridData = @(
        foreach ($App in $Apps) {

            ConvertTo-AppGridObject `
                -App $App

        }
    )

    return $GridData

}

Export-ModuleMember `
    -Function `
    Get-IntuneWin32Apps,
    Get-AppAssignmentCount,
    Get-AppAssignments,
    ConvertTo-AppGridObject,
    Export-AppsToCsv,
    Backup-AppsToJson,
    Remove-IntuneWin32App,
    Remove-SelectedApps,
    Search-Apps,
    Get-AppGridData