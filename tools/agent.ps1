# Run an app's agent scenarios (niello/agent) headless and print what they
# found. A scenario is an @(test) in the app's package, inside
# `when niello.NIELLO_DEBUG { ... }`; this builds with that define. Reports
# land in .\agent-out\<scenario>\ (snapshots, findings.txt, summary.txt),
# under the directory you run it from; set NIELLO_AGENT_OUT to put them
# elsewhere. Needs odin on PATH.
#
#	tools\agent.ps1 niello\examples\showcase                  every scenario (and the app's other tests)
#	tools\agent.ps1 niello\examples\showcase showcase_pages   one scenario
param(
	[Parameter(Mandatory = $true)][string]$Package,
	[string]$Scenario = ""
)
$ErrorActionPreference = "Stop"
$out = if ($env:NIELLO_AGENT_OUT) { $env:NIELLO_AGENT_OUT } else { "agent-out" }
$odinArgs = @("-define:ODIN_TEST_THREADS=1", "-define:NIELLO_DEBUG=true", "-define:NIELLO_AGENT_OUT=$out")
if ($Scenario -ne "") {
	$line = Get-ChildItem -Path $Package -Filter *.odin | Select-String -Pattern '^package (\w+)' | Select-Object -First 1
	$name = $line.Matches[0].Groups[1].Value
	$odinArgs += "-define:ODIN_TEST_NAMES=$name.$Scenario"
}
$bin = Join-Path ([System.IO.Path]::GetTempPath()) "niello-agent-test.exe"
& odin test $Package @odinArgs "-out:$bin"
exit $LASTEXITCODE
