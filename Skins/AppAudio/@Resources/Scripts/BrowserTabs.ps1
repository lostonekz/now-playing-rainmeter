<#
.SYNOPSIS
    Finds the browser tab that is making sound. Dot-sourced by Get-AppAudio.ps1 and Focus-App.ps1.

.DESCRIPTION
    Chromium browsers (Chrome, Edge, Brave, Opera, Vivaldi) put the tab's audio state
    in its accessible name: "<title> - Audio playing". UI Automation reads it from the
    tab strip, minimized windows included, and the same element can be selected to
    switch to that tab.

    This is needed because Chrome reports a single media session to Windows - the
    tab that made sound most recently. A notification ping in another tab takes that
    slot from a video that has been playing for an hour, so the media session alone
    points at the wrong tab.

    The marker is the English UI string. A browser in another UI language, or Firefox,
    which does not expose it, finds nothing here and falls back to the window title.
#>

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$script:audioTabMarker = ' - Audio playing'

# Everything Chromium appends after the title, from the first marker on.
$script:tabSuffixPattern = '\s-\s(Audio playing|Audio muted|High memory usage|Memory usage|Network error|Crashed)\b.*$'

function ConvertFrom-TabName {
    param([string]$Name)
    ($Name -replace $script:tabSuffixPattern, '').Trim()
}

# The first tab marked as playing audio, in the windows of these processes, or $null.
# Returns the tab element (to select it), its window handle and its cleaned title.
function Find-AudioTab {
    param([int[]]$ProcessIds)
    if (-not $ProcessIds) { return $null }

    $ae = [System.Windows.Automation.AutomationElement]
    $byProcess = [System.Windows.Automation.Condition[]]@(
        $ProcessIds | ForEach-Object { New-Object System.Windows.Automation.PropertyCondition($ae::ProcessIdProperty, $_) }
    )
    $windowCondition = if ($byProcess.Count -eq 1) { $byProcess[0] }
                       else { New-Object System.Windows.Automation.OrCondition($byProcess) }
    $tabCondition = New-Object System.Windows.Automation.PropertyCondition(
        $ae::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)

    $windows = $ae::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $windowCondition)
    foreach ($window in $windows) {
        try {
            $tabs = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabCondition)
        } catch { continue }   # window closed mid-walk
        foreach ($tab in $tabs) {
            $name = $tab.Current.Name
            if ($name -and $name.Contains($script:audioTabMarker)) {
                return [pscustomobject]@{
                    Element = $tab
                    Hwnd    = [long]$window.Current.NativeWindowHandle
                    Title   = ConvertFrom-TabName $name
                }
            }
        }
    }
    $null
}
