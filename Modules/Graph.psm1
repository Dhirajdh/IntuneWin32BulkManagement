# ==========================================
# Graph.psm1
# Intune Win32 Bulk Management
# ==========================================

# Public Client ID used by Microsoft tools
# Can be replaced later with your own App Registration
$Script:ClientId = "ad85eb34-8b05-49ac-88e5-575f6dc51472"

$Script:TenantId = "organizations"

$Script:AccessToken = $null

$Script:Headers = $null

# --------------------------------------------------
# Load MSAL
# --------------------------------------------------

function Initialize-MSAL {

    try {

        $Module =
            Get-Module `
                MSAL.PS `
                -ListAvailable |
            Select-Object -First 1

        if (-not $Module) {

            throw "MSAL.PS module not found. Install-Module MSAL.PS -Scope CurrentUser"

        }

        Import-Module `
            MSAL.PS `
            -Force

        return $true

    }
    catch {

        throw $_

    }

}

# --------------------------------------------------
# Connect
# --------------------------------------------------

function Connect-Intune {

try {

    Write-UILog `
        -Message "Connecting to Microsoft Graph..."

    Connect-MgGraph `
        -Scopes `
        "DeviceManagementApps.ReadWrite.All",
        "Directory.Read.All" `
        -NoWelcome

    $Context = Get-MgContext

    Write-UILog `
        -Message "Connected as $($Context.Account)" `
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
# Disconnect
# --------------------------------------------------

function Disconnect-Intune {

    try {

        Disconnect-MgGraph

        Write-UILog `
            -Message "Disconnected"

    }
    catch {

    }

}

# --------------------------------------------------
# Get Access Token
# --------------------------------------------------

function Get-AccessToken {

    return $Script:AccessToken

}

# --------------------------------------------------
# Check Authentication
# --------------------------------------------------

function Test-GraphConnection {

    if ([string]::IsNullOrWhiteSpace(
        $Script:AccessToken
    )) {

        return $false

    }

    return $true

}

# --------------------------------------------------
# Generic Graph GET
# --------------------------------------------------

function Invoke-GraphGet {

    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    try {

        # Use MgGraph auth context (avoids 401 when $Script:Headers is not initialized)
        Invoke-MgGraphRequest `
            -Method GET `
            -Uri $Uri

    }
    catch {

        Write-UILog `
            -Message $_.Exception.Message `
            -Level ERROR

        throw

    }

}

# --------------------------------------------------
# Generic Graph DELETE
# --------------------------------------------------

function Invoke-GraphDelete {

    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    try {

        Invoke-MgGraphRequest `
            -Method DELETE `
            -Uri $Uri

    }
    catch {

        Write-UILog `
            -Message $_.Exception.Message `
            -Level ERROR

        throw

    }

}

# --------------------------------------------------
# Generic Graph POST
# --------------------------------------------------

function Invoke-GraphPost {

    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [object]$Body
    )

    try {

        Invoke-MgGraphRequest `
            -Method POST `
            -Uri $Uri `
            -Body ($Body | ConvertTo-Json -Depth 20) `
            -ContentType "application/json"

    }
    catch {

        Write-UILog `
            -Message $_.Exception.Message `
            -Level ERROR

        throw

    }

}

# --------------------------------------------------
# Get Current User
# --------------------------------------------------

function Get-CurrentUser {

    $Uri =
        "https://graph.microsoft.com/v1.0/me"

    Invoke-GraphGet `
        -Uri $Uri

}

# --------------------------------------------------
# Get Tenant Details
# --------------------------------------------------

function Get-TenantDetails {

    $Uri =
        "https://graph.microsoft.com/v1.0/organization"

    $Result =
        Invoke-GraphGet `
        -Uri $Uri

    return $Result.value[0]

}

# --------------------------------------------------
# Get Tenant Summary
# --------------------------------------------------

function Get-ConnectionInfo {
	
$Org =
    Invoke-MgGraphRequest `
    -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/organization"

$Context =
    Get-MgContext

[PSCustomObject]@{

    TenantName =
        $Org.value[0].displayName

    TenantId =
        $Org.value[0].id

    User =
        $Context.Account

}


}


# --------------------------------------------------
# Graph Pagination
# --------------------------------------------------

function Get-AllGraphPages {

    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $Results =
        @()

    do {

        $Response =
            Invoke-GraphGet `
            -Uri $Uri

        $Results +=
            $Response.value

        $Uri =
            $Response.'@odata.nextLink'

    }
    while ($Uri)

    return $Results

}

Export-ModuleMember `
    -Function `
    Connect-Intune,
    Disconnect-Intune,
    Get-AccessToken,
    Test-GraphConnection,
    Invoke-GraphGet,
    Invoke-GraphPost,
    Invoke-GraphDelete,
    Get-CurrentUser,
    Get-TenantDetails,
    Get-ConnectionInfo,
    Get-AllGraphPages