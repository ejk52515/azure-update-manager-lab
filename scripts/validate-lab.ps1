param([string]$ResourceGroup="rg-aumlab", [string]$SubscriptionId)

Connect-AzAccount -SubscriptionId $SubscriptionId

$vms     = @("DC01","WS01","WS02")
$results = @()
$allPass = $true

Write-Host "`n=== Azure Update Manager Compliance Validation ===" -ForegroundColor Cyan

foreach ($vm in $vms) {
    $assessment = Get-AzVMPatchAssessmentResult `
        -ResourceGroupName $ResourceGroup `
        -VMName $vm `
        -ErrorAction SilentlyContinue

    # PASS = assessment ran successfully AND no Critical/Security patches are missing.
    # A brand-new VM will often FAIL this check — it has patches outstanding.
    # This is the correct and expected result: the lab is working as designed.
    # Apply patches via the maintenance window to resolve it.
    $compliant = $assessment.Status -eq "Succeeded" -and $assessment.CriticalAndSecurityPatchCount -eq 0
    $status    = if ($compliant) { "PASS" } else { "FAIL" }
    if (-not $compliant) { $allPass = $false }

    Write-Host "[$status] $vm -- Critical missing: $($assessment.CriticalAndSecurityPatchCount) | Status: $($assessment.Status)"

    $results += [PSCustomObject]@{
        VMName                   = $vm
        AssessmentStatus         = $assessment.Status
        CriticalAndSecurityCount = $assessment.CriticalAndSecurityPatchCount
        OtherPatchCount          = $assessment.OtherPatchCount
        LastAssessmentTime       = $assessment.StartDateTime
        Compliant                = $compliant
        Result                   = $status
    }
}

Write-Host ""
Write-Host "Overall: $(if ($allPass){"ALL PASS"}else{"FAILURES DETECTED"})" `
    -ForegroundColor $(if ($allPass){"Green"}else{"Red"})

# Export JSON — feeds SIEM, ServiceNow, or compliance dashboard in production
$report = @{
    GeneratedAt   = (Get-Date -Format "o")
    ResourceGroup = $ResourceGroup
    VMs           = $results
}
$report | ConvertTo-Json -Depth 5 | Out-File "./aum-compliance-report.json" -Encoding UTF8
Write-Host "Report exported: aum-compliance-report.json" -ForegroundColor Cyan