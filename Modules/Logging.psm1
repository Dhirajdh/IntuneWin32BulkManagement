# ==========================================
# Logging.psm1
# Intune Win32 Bulk Management
# ==========================================

$Script:LogControl = $null

function Set-LogControl {

    param(
        [Parameter(Mandatory)]
        [System.Windows.Controls.TextBox]$TextBox
    )

    $Script:LogControl = $TextBox
}

function Write-UILog {

    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet(
            "INFO",
            "SUCCESS",
            "WARNING",
            "ERROR"
        )]
        [string]$Level = "INFO"
    )

    try {

        $Timestamp =
            Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        $LogEntry =
            "[$Timestamp] [$Level] $Message"

        Write-Host $LogEntry

        if ($Script:LogControl) {

            $Script:LogControl.Dispatcher.Invoke({

		$Script:LogControl.AppendText(
			"$LogEntry`r`n"
		)

		$Script:LogControl.UpdateLayout()

		$Script:LogControl.ScrollToEnd()

            })

        }

    }
    catch {

        Write-Host $_.Exception.Message

    }
}

function Write-Separator {

    Write-UILog `
        -Message "--------------------------------------------------"
}

function Clear-UILog {

    if ($Script:LogControl) {

        $Script:LogControl.Dispatcher.Invoke({

            $Script:LogControl.Clear()

        })

    }
}

function Export-Log {

    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {

        if (-not $Script:LogControl) {
            return
        }

        $Script:LogControl.Dispatcher.Invoke({

            $Script:LogControl.Text |
                Set-Content `
                -Path $Path `
                -Encoding UTF8

        })

        Write-UILog `
            -Message "Log exported to $Path" `
            -Level SUCCESS

    }
    catch {

        Write-UILog `
            -Message $_.Exception.Message `
            -Level ERROR

    }
}

function Initialize-Logging {

    param(
        [Parameter(Mandatory)]
        [System.Windows.Controls.TextBox]$TextBox
    )

    Set-LogControl $TextBox

    Write-Separator

    Write-UILog `
        -Message "Intune Win32 Bulk Management Started" `
        -Level SUCCESS

    Write-Separator
}

Export-ModuleMember `
    -Function `
    Initialize-Logging,
    Write-UILog,
    Write-Separator,
    Clear-UILog,
    Export-Log