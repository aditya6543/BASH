$Profile = "default"
$Region  = "us-east-1"   # S3 global endpoint

Write-Host "Listing all S3 buckets..."

# FORCE array split
$BucketsRaw = aws s3api list-buckets `
    --profile $Profile `
    --query "Buckets[].Name" `
    --output text

$Buckets = $BucketsRaw -split "\s+"

foreach ($Bucket in $Buckets) {

    if ([string]::IsNullOrWhiteSpace($Bucket)) {
        continue
    }

    Write-Host "===================================="
    Write-Host "Processing bucket: $Bucket"
    Write-Host "===================================="

    # List versions + delete markers
    $VersionsJson = aws s3api list-object-versions `
        --bucket $Bucket `
        --region $Region `
        --profile $Profile `
        --output json 2>$null

    if ($LASTEXITCODE -eq 0 -and $VersionsJson) {
        $Parsed = $VersionsJson | ConvertFrom-Json

        $AllObjects = @()
        if ($Parsed.Versions) { $AllObjects += $Parsed.Versions }
        if ($Parsed.DeleteMarkers) { $AllObjects += $Parsed.DeleteMarkers }

        foreach ($Obj in $AllObjects) {
            Write-Host "Deleting object $($Obj.Key) version $($Obj.VersionId)"

            aws s3api delete-object `
                --bucket $Bucket `
                --key $Obj.Key `
                --version-id $Obj.VersionId `
                --region $Region `
                --profile $Profile | Out-Null
        }
    }

    # Non-versioned safety wipe
    aws s3 rm "s3://$Bucket" `
        --recursive `
        --profile $Profile 2>$null

    Write-Host "Deleting bucket $Bucket"

    aws s3api delete-bucket `
        --bucket $Bucket `
        --region $Region `
        --profile $Profile
}

Write-Host "DONE: All S3 buckets processed."
