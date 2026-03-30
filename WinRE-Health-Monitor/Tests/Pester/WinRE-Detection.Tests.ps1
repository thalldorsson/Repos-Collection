Describe "WinRE Detection Script" {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\..\Scripts\Detection\WinRE-Health-Detection-NinjaOne-Simple.ps1"
        $scriptContent = Get-Content -Path $scriptPath -Raw
    }

    Context "WinRE Status Detection" {
        It "Should parse reagentc output for WinRE enabled state" {
            $scriptContent | Should -Match 'reagentc\s+/info'
            $scriptContent | Should -Match 'Windows RE status'
            $scriptContent | Should -Match 'WinREEnabled\s*=\s*\$statusLine\s+-match\s+"Enabled"'
        }

        It "Should calculate partition size and free space values" {
            $scriptContent | Should -Match 'PartitionSizeMB\s*=\s*\[math\]::Round\(\$partition\.Size\s*/\s*1MB,\s*2\)'
            $scriptContent | Should -Match 'PartitionFreeMB\s*=\s*\[math\]::Round\(\$result\.PartitionSizeMB\s*-\s*\$wimSizeMB,\s*2\)'
        }
    }

    Context "KB5034441 Vulnerability Check" {
        It "Should identify vulnerable partitions using free-space threshold" {
            $scriptContent | Should -Match 'KB5034441Vulnerable\s*=\s*\(\$result\.PartitionFreeMB\s+-lt\s+250\)'
        }

        It "Should fallback to partition-size threshold when free space is unavailable" {
            $scriptContent | Should -Match 'KB5034441Vulnerable\s*=\s*\(\$result\.PartitionSizeMB\s+-lt\s+500\)'
        }
    }

    Context "Severity Calculation" {
        It "Should assign Critical severity for low confidence or vulnerability" {
            $scriptContent | Should -Match '\$result\.Severity\s*=\s*"Critical"'
            $scriptContent | Should -Match 'if\s*\(\$result\.KB5034441Vulnerable\)\s*\{\s*\$result\.Severity\s*=\s*"Critical"'
        }

        It "Should map confidence score bands to Healthy/Warning/Critical" {
            $scriptContent | Should -Match 'if\s*\(\$result\.ConfidenceScore\s+-ge\s+85\)'
            $scriptContent | Should -Match 'elseif\s*\(\$result\.ConfidenceScore\s+-ge\s+60\)'
        }
    }
}
