# The ScheduledTasks commands exist only on Windows. Elsewhere (Linux, macOS)
# empty stand-ins are defined so Pester can mock them; on Windows nothing is
# defined here and the tests mock the real commands.
if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
    function global:Register-ScheduledTask { param($TaskName, $Xml, [switch]$Force) }
    function global:Get-ScheduledTask { param($TaskName) }
    function global:Start-ScheduledTask { param($TaskName) }
    function global:Unregister-ScheduledTask { param($TaskName, [switch]$Confirm) }
}
