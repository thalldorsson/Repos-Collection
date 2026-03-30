#Requires -Module Pester

BeforeAll {
    # Import module
    $modulePath = Join-Path $PSScriptRoot '..' 'PhishIR.psd1'
    Import-Module $modulePath -Force
    
    # Create test directory
    $script:TestMetricsDir = Join-Path $TestDrive 'Metrics'
    $script:TestMetricsFile = Join-Path $script:TestMetricsDir 'metrics.jsonl'
}

Describe 'Send-PhishIRMetric' {
    
    BeforeEach {
        # Clean test directory
        if (Test-Path $script:TestMetricsDir) {
            Remove-Item -Path $script:TestMetricsDir -Recurse -Force
        }
        New-Item -ItemType Directory -Path $script:TestMetricsDir -Force | Out-Null
        
        # Mock Get-PhishIRStoragePath
        Mock Get-PhishIRStoragePath {
            param($PathType, [switch]$CreateIfMissing)
            
            if ($PathType -eq 'All') {
                return [PSCustomObject]@{
                    Reports = $script:TestMetricsDir
                }
            }
            return $script:TestMetricsDir
        }
    }
    
    Context 'Basic Metric Logging' {
        
        It 'Should create metrics.jsonl file if it does not exist' {
            Test-Path $script:TestMetricsFile | Should -Be $false
            
            Send-PhishIRMetric -MetricName 'test.metric' -Value 42
            
            Test-Path $script:TestMetricsFile | Should -Be $true
        }
        
        It 'Should append metric as JSONL (one line per metric)' {
            Send-PhishIRMetric -MetricName 'test.metric1' -Value 10
            Send-PhishIRMetric -MetricName 'test.metric2' -Value 20
            
            $lines = Get-Content $script:TestMetricsFile
            $lines.Count | Should -Be 2
        }
        
        It 'Should create valid JSON for each metric' {
            Send-PhishIRMetric -MetricName 'test.metric' -Value 42
            
            $json = Get-Content $script:TestMetricsFile -Raw
            $metric = $json | ConvertFrom-Json
            
            $metric.MetricName | Should -Be 'test.metric'
            $metric.Value | Should -Be 42
            $metric.Timestamp | Should -Not -BeNullOrEmpty
        }
    }
    
    Context 'Metric Schema' {
        
        It 'Should include timestamp in ISO8601 format' {
            Send-PhishIRMetric -MetricName 'test.metric' -Value 42
            
            $metric = Get-Content $script:TestMetricsFile | ConvertFrom-Json
            $metric.Timestamp | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
        }
        
        It 'Should include metric name' {
            Send-PhishIRMetric -MetricName 'incident.created' -Value 1
            
            $metric = Get-Content $script:TestMetricsFile | ConvertFrom-Json
            $metric.MetricName | Should -Be 'incident.created'
        }
        
        It 'Should include metric value' {
            Send-PhishIRMetric -MetricName 'signins.queried' -Value 150
            
            $metric = Get-Content $script:TestMetricsFile | ConvertFrom-Json
            $metric.Value | Should -Be 150
        }
        
        It 'Should include unit when specified' {
            Send-PhishIRMetric -MetricName 'duration' -Value 1.5 -Unit 'seconds'
            
            $metric = Get-Content $script:TestMetricsFile | ConvertFrom-Json
            $metric.Unit | Should -Be 'seconds'
        }
        
        It 'Should include tags when specified' {
            $tags = @{ Severity = 'High'; Type = 'ExcelPhishing' }
            Send-PhishIRMetric -MetricName 'incident.created' -Value 1 -Tags $tags
            
            $metric = Get-Content $script:TestMetricsFile | ConvertFrom-Json
            $metric.Tags.Severity | Should -Be 'High'
            $metric.Tags.Type | Should -Be 'ExcelPhishing'
        }
    }
    
    Context 'Tags Support' {
        
        It 'Should handle multiple tags' {
            $tags = @{
                Environment = 'Production'
                Region = 'US-West'
                Team = 'SOC'
            }
            Send-PhishIRMetric -MetricName 'test.metric' -Value 1 -Tags $tags
            
            $metric = Get-Content $script:TestMetricsFile | ConvertFrom-Json
            $metric.Tags.Environment | Should -Be 'Production'
            $metric.Tags.Region | Should -Be 'US-West'
            $metric.Tags.Team | Should -Be 'SOC'
        }
        
        It 'Should handle null/empty tags gracefully' {
            Send-PhishIRMetric -MetricName 'test.metric' -Value 1
            
            $metric = Get-Content $script:TestMetricsFile | ConvertFrom-Json
            # Tags may be null or empty object
            $metric.PSObject.Properties.Name | Should -Contain 'Tags'
        }
    }
    
    Context 'Common Metric Patterns' {
        
        It 'Should log incident creation metric' {
            Send-PhishIRMetric -MetricName 'incident.created' -Value 1 -Tags @{ Severity = 'High' }
            
            $metric = Get-Content $script:TestMetricsFile | ConvertFrom-Json
            $metric.MetricName | Should -Be 'incident.created'
            $metric.Value | Should -Be 1
            $metric.Tags.Severity | Should -Be 'High'
        }
        
        It 'Should log sign-in query count' {
            Send-PhishIRMetric -MetricName 'signins.queried' -Value 100 -Unit 'count'
            
            $metric = Get-Content $script:TestMetricsFile | ConvertFrom-Json
            $metric.MetricName | Should -Be 'signins.queried'
            $metric.Value | Should -Be 100
            $metric.Unit | Should -Be 'count'
        }
        
        It 'Should log performance duration' {
            Send-PhishIRMetric -MetricName 'signins.query.duration' -Value 1.234 -Unit 'seconds'
            
            $metric = Get-Content $script:TestMetricsFile | ConvertFrom-Json
            $metric.MetricName | Should -Be 'signins.query.duration'
            $metric.Value | Should -Be 1.234
            $metric.Unit | Should -Be 'seconds'
        }
    }
    
    Context 'Thread Safety' {
        
        It 'Should handle concurrent writes without corruption' {
            $jobs = 1..10 | ForEach-Object {
                Start-Job -ScriptBlock {
                    param($ModulePath, $MetricsFile, $JobId)
                    Import-Module $ModulePath -Force
                    
                    Mock Get-PhishIRStoragePath {
                        return [PSCustomObject]@{
                            Reports = Split-Path $MetricsFile -Parent
                        }
                    }
                    
                    Send-PhishIRMetric -MetricName "test.metric.$JobId" -Value $JobId
                } -ArgumentList $modulePath, $script:TestMetricsFile, $_
            }
            
            $jobs | Wait-Job | Receive-Job
            $jobs | Remove-Job
            
            $lines = Get-Content $script:TestMetricsFile
            $lines.Count | Should -Be 10
            
            # Each line should be valid JSON
            foreach ($line in $lines) {
                { $line | ConvertFrom-Json } | Should -Not -Throw
            }
        }
    }
    
    Context 'Error Handling' {
        
        It 'Should throw when MetricName is empty' {
            { Send-PhishIRMetric -MetricName '' -Value 42 } | Should -Throw
        }
        
        It 'Should throw when Value is not numeric' {
            { Send-PhishIRMetric -MetricName 'test.metric' -Value 'not-a-number' } | Should -Throw
        }
        
        It 'Should handle missing storage path gracefully' {
            Mock Get-PhishIRStoragePath { throw 'Storage path not configured' }
            
            # Should fallback to module root path
            { Send-PhishIRMetric -MetricName 'test.metric' -Value 42 } | Should -Not -Throw
        }
    }
    
    Context 'Integration with Dashboards' {
        
        It 'Should produce Power BI compatible JSONL' {
            Send-PhishIRMetric -MetricName 'incident.created' -Value 1 -Tags @{ Type = 'Phishing' }
            Send-PhishIRMetric -MetricName 'incident.created' -Value 1 -Tags @{ Type = 'Malware' }
            
            $metrics = Get-Content $script:TestMetricsFile | ForEach-Object { $_ | ConvertFrom-Json }
            
            # Power BI can query by MetricName and aggregate by Tags
            $phishingIncidents = $metrics | Where-Object { $_.MetricName -eq 'incident.created' -and $_.Tags.Type -eq 'Phishing' }
            $phishingIncidents.Count | Should -Be 1
        }
        
        It 'Should support KQL-style queries on JSONL' {
            Send-PhishIRMetric -MetricName 'incident.created' -Value 1 -Tags @{ Severity = 'High' }
            Send-PhishIRMetric -MetricName 'incident.created' -Value 1 -Tags @{ Severity = 'Medium' }
            Send-PhishIRMetric -MetricName 'incident.created' -Value 1 -Tags @{ Severity = 'High' }
            
            $metrics = Get-Content $script:TestMetricsFile | ForEach-Object { $_ | ConvertFrom-Json }
            
            # Simulate: summarize count() by Tags.Severity
            $summary = $metrics | Group-Object { $_.Tags.Severity } | 
                Select-Object @{N='Severity';E={$_.Name}}, Count
            
            $highSev = $summary | Where-Object { $_.Severity -eq 'High' }
            $highSev.Count | Should -Be 2
        }
    }
}

AfterAll {
    # Cleanup
    if (Test-Path $script:TestMetricsDir) {
        Remove-Item -Path $script:TestMetricsDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
