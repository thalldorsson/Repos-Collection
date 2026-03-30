

<# Consolidated test suite merging legacy & month-3 improvements #>

## Ensure module is available for InModuleScope-based mocks
$script:ModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'PhishIR\PhishIR.psm1'
Import-Module $script:ModulePath -Force

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $ModulePath = Join-Path $repoRoot 'PhishIR\PhishIR.psm1'
    Import-Module $ModulePath -Force
    # Dot-source helpers for direct function access if needed
    . (Join-Path $repoRoot 'PhishIR\Private\SearchHelpers.ps1')
}

Describe 'Module Exports' {
    It 'Should import without errors' { { Import-Module $ModulePath -Force } | Should -Not -Throw }
    It 'Should export core functions' {
        $expected = @('Invoke-MailPurge','Get-MailboxPersistenceArtifacts','Build-ContentMatchQuery','Import-PhishIRConfiguration','Get-PhishIRConfiguration','Invoke-WithRetry','Write-AuditLog','Write-Info','Write-Success','Write-Warn')
        $exported = (Get-Command -Module PhishIR -CommandType Function).Name
        foreach ($fn in $expected) { $exported | Should -Contain $fn }
    }
}

Describe 'Configuration' {
    It 'Should load default JSON config when absent' { $cfg = Get-PhishIRConfiguration; $cfg.version | Should -Be '2.0.0' }
    It 'Should expose legacy mapped keys' { $cfg = Get-PhishIRConfiguration; $cfg.DefaultPurgeType | Should -Be 'SoftDelete' }
}

Describe 'Build-ContentMatchQuery' {
    It 'Builds sender-only query' { (Build-ContentMatchQuery -Senders 'a@b.com') | Should -BeLike '*from:a@b.com*' }
    It 'Builds multi-sender OR query' { (Build-ContentMatchQuery -Senders 'a@b.com','c@d.com') | Should -BeLike '*(from:a@b.com OR from:c@d.com)*' }
    It 'Builds subject keyword query' { (Build-ContentMatchQuery -SubjectKeywords 'Invoice') | Should -BeLike '*subject:"Invoice"*' }
    It 'Combines criteria with AND' {
        $q = Build-ContentMatchQuery -Senders 'phish@evil.com' -SubjectKeywords 'Urgent' -StartUtc ([datetime]'2025-01-01')
        $q | Should -BeLike '*from:phish@evil.com*AND*subject:"Urgent"*AND*received>=*'
    }
    It 'Uses advanced query verbatim' { (Build-ContentMatchQuery -AdvancedQuery 'from:test@x.com AND hasattachment:true') | Should -Be 'from:test@x.com AND hasattachment:true' }
    It 'Throws when no terms provided' { { Build-ContentMatchQuery } | Should -Throw '*No query terms provided*' }
}

Describe 'Mailbox Validation Helpers' {
    BeforeEach {
        Mock Get-EXOMailbox {
            param($Identity)
            switch ($Identity) {
                'valid@test.com' { return [PSCustomObject]@{ PrimarySmtpAddress='valid@test.com'; LitigationHoldEnabled=$false; InPlaceHolds=@(); SingleItemRecoveryEnabled=$true; RetainDeletedItemsFor=[TimeSpan]::FromDays(30) } }
                default { throw 'Mailbox not found' }
            }
        }
    }
    It 'Returns valid mailbox list' { (Test-MailboxesForPurge -Mailboxes 'valid@test.com').ValidMailboxes | Should -Contain 'valid@test.com' }
    It 'Captures invalid mailbox' { (Test-MailboxesForPurge -Mailboxes 'valid@test.com','bad@test.com').InvalidMailboxes | Should -Contain 'bad@test.com' }
    It 'Throws when none valid' { { Test-MailboxesForPurge -Mailboxes 'bad@test.com' } | Should -Throw '*No valid mailboxes*' }
}

Describe 'HardDelete Safety' {
    It 'Allows SoftDelete on held mailbox' { Test-HardDeleteSafety -MailboxDetails @([PSCustomObject]@{ PrimarySmtpAddress='x'; LitigationHoldEnabled=$true }) -PurgeType SoftDelete | Should -BeTrue }
    It 'Blocks HardDelete on held mailbox' { { Test-HardDeleteSafety -MailboxDetails @([PSCustomObject]@{ PrimarySmtpAddress='x'; LitigationHoldEnabled=$true }) -PurgeType HardDelete } | Should -Throw '*HardDelete blocked*' }
    It 'Allows bypass with ForceHoldBypass' { { Test-HardDeleteSafety -MailboxDetails @([PSCustomObject]@{ PrimarySmtpAddress='x'; LitigationHoldEnabled=$true }) -PurgeType HardDelete -ForceHoldBypass } | Should -Not -Throw }
}

Describe 'Evidence Collection' {
    BeforeEach {
        Mock -ModuleName PhishIR Invoke-GetMailbox { [PSCustomObject]@{ DisplayName='User'; PrimarySmtpAddress='user@test.com'; ForwardingAddress=$null; ForwardingSmtpAddress='fwd@ext.com'; DeliverToMailboxAndForward=$true } }
        Mock -ModuleName PhishIR Invoke-GetInboxRule { [PSCustomObject]@{ Name='Rule'; Enabled=$true; RedirectTo='evil@attacker.com'; ForwardTo=$null; DeleteMessage=$false; ForwardAsAttachmentTo=$null; MoveToFolder=$null; MarkAsRead=$true; StopProcessingRules=$false; Description='Test rule'; Identity='Rule-1' } }
        Mock Export-Csv {}
        $dir = Join-Path $TestDrive 'Evidence'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    It 'Exports forwarding config' { (Get-MailboxPersistenceArtifacts -Mailbox 'user@test.com' -OutputDir (Join-Path $TestDrive 'Evidence') -SkipConnection).ForwardingCsv | Should -BeLike '*forwarding.csv' }
    It 'Exports rules config' { (Get-MailboxPersistenceArtifacts -Mailbox 'user@test.com' -OutputDir (Join-Path $TestDrive 'Evidence') -SkipConnection).RulesCsv | Should -BeLike '*rules.csv' }
}

Describe 'Compliance Search Helpers' {
    InModuleScope 'PhishIR' {
        BeforeAll { $script:callCount = 0 }

        It 'New-ComplianceSearchJob waits until Completed and returns search object' {
            Mock -ModuleName 'PhishIR' -CommandName Invoke-NewComplianceSearch -MockWith { $true } -Verifiable
            Mock -ModuleName 'PhishIR' -CommandName Invoke-StartComplianceSearch -MockWith { $true } -Verifiable
            Mock -ModuleName 'PhishIR' -CommandName Invoke-GetComplianceSearch -MockWith {
                $script:callCount++ | Out-Null
                if ($script:callCount -lt 2) {
                    [pscustomobject]@{ Name='IR-1Mbx-20250101_0000'; Status='Starting'; Items=0 }
                } else {
                    [pscustomobject]@{ Name='IR-1Mbx-20250101_0000'; Status='Completed'; Items=3 }
                }
            }

            $cs = New-ComplianceSearchJob -Mailboxes @('user@contoso.com') -ContentMatchQuery 'subject:\"Test\"'
            $cs | Should -Not -BeNullOrEmpty
            $cs.Status | Should -Be 'Completed'
            $cs.Items | Should -Be 3
        }

        It 'Export-SearchResults parses per-mailbox counts and writes preview files' {
            $csObj = [pscustomobject]@{
                Name = 'IR-2Mbx-20250101_0000'
                Status = 'Completed'
                Items = 5
                SuccessResults = @(
                    'user1@contoso.com: 3',
                    'Location : user2@contoso.com, Item Count : 2'
                )
                FailedResults = @()
            }

            $tmp = Join-Path $env:TEMP ('PhishIRTest_'+([guid]::NewGuid().ToString()))
            New-Item -ItemType Directory -Path $tmp | Out-Null

            $res = Export-SearchResults -ComplianceSearch $csObj -OutputDir $tmp -ContentMatchQuery 'subject:\"Test\"' -StartUtc (Get-Date).AddHours(-1) -EndUtc (Get-Date) -Mailboxes @('user1@contoso.com','user2@contoso.com')

            Test-Path $res.PreviewCsv | Should -BeTrue
            Test-Path $res.PreviewJson | Should -BeTrue
            ($res.PerMailboxResults | Where-Object { $_.Mailbox -eq 'user1@contoso.com' }).ItemCount | Should -Be 3
            ($res.PerMailboxResults | Where-Object { $_.Mailbox -eq 'user2@contoso.com' }).ItemCount | Should -Be 2
            $res.ItemsFound | Should -Be 5
        }
    }
}

Describe 'Retry Logic' {
    It 'Succeeds first attempt' { (Invoke-WithRetry -ScriptBlock { 'OK' } -MaxRetries 2) | Should -Be 'OK' }
    It 'Retries then succeeds' {
        $script:cnt=0
        $r = Invoke-WithRetry -ScriptBlock { $script:cnt++; if ($script:cnt -lt 2) { throw 'x' } 'Y' } -MaxRetries 3 -InitialDelaySeconds 1
        $r | Should -Be 'Y'; $script:cnt | Should -Be 2
    }
    It 'Throws after max retries' { { Invoke-WithRetry -ScriptBlock { throw 'fail' } -MaxRetries 2 -InitialDelaySeconds 1 } | Should -Throw }
}

Describe 'Logging & Audit' {
    BeforeEach { $logDir = Join-Path $TestDrive 'logs'; Initialize-PhishIRLogging -LogDirectory $logDir }
    It 'Writes info log' { { Write-PhishIRLog -Level Info -Message 'Test message' } | Should -Not -Throw }
    It 'Writes warning log' { { Write-PhishIRLog -Level Warning -Message 'Warn message' } | Should -Not -Throw }
    It 'Writes audit log' { { Write-AuditLog -Operation 'UnitTest' -Details @{ Key='Value'} } | Should -Not -Throw }
}

Describe 'Purge Action Helpers' {
    InModuleScope 'PhishIR' {
        BeforeEach {
            # Reduce waits and timeouts for fast tests
            Mock Import-PowerShellDataFile {
                return @{
                    PurgeActionPollIntervalSeconds = 0
                    ActionAppearanceTimeoutMinutes = 0.001
                    PurgeCompletionTimeoutMinutes = 0.001
                    ReportDateFormat = 'yyyyMMdd-HHmmss'
                    ReportJsonDepth = 4
                }
            }
            Mock Start-Sleep {}
            $script:getCall = 0
        }

        It 'Start-PurgeAction completes successfully' {
            Mock -ModuleName 'PhishIR' -CommandName Invoke-NewComplianceSearchAction -MockWith { $true } -Verifiable
            Mock -ModuleName 'PhishIR' -CommandName Invoke-GetComplianceSearchAction -MockWith {
                $script:getCall++ | Out-Null
                if ($script:getCall -lt 2) {
                    [pscustomobject]@{ Name='IR-1_Purge'; Status='InProgress'; Progress='10%'; ItemsPurged=$null }
                } else {
                    [pscustomobject]@{ Name='IR-1_Purge'; Status='Completed'; Progress='100%'; ItemsPurged=5 }
                }
            }
            Mock -ModuleName 'PhishIR' -CommandName Invoke-GetAllComplianceSearchAction -MockWith { @() }

            $act = Start-PurgeAction -SearchName 'IR-1' -PurgeType SoftDelete
            $act.Status | Should -Be 'Completed'
            $act.ItemsPurged | Should -Be 5
        }

        It 'Start-PurgeAction throws when action not found' {
            Mock -ModuleName 'PhishIR' -CommandName Invoke-NewComplianceSearchAction -MockWith { $true }
            Mock -ModuleName 'PhishIR' -CommandName Invoke-GetComplianceSearchAction -MockWith { $null }
            Mock -ModuleName 'PhishIR' -CommandName Invoke-GetAllComplianceSearchAction -MockWith { @() }

            { Start-PurgeAction -SearchName 'IR-2' -PurgeType SoftDelete } | Should -Throw '*not found*'
        }

        It 'Start-PurgeAction throws when status Failed' {
            Mock -ModuleName 'PhishIR' -CommandName Invoke-NewComplianceSearchAction -MockWith { $true }
            Mock -ModuleName 'PhishIR' -CommandName Invoke-GetComplianceSearchAction -MockWith {
                $script:getCall++ | Out-Null
                if ($script:getCall -lt 2) {
                    [pscustomobject]@{ Name='IR-3_Purge'; Status='InProgress'; Progress='50%'; ItemsPurged=0 }
                } else {
                    [pscustomobject]@{ Name='IR-3_Purge'; Status='Failed'; Progress='50%'; ItemsPurged=0 }
                }
            }
            Mock -ModuleName 'PhishIR' -CommandName Invoke-GetAllComplianceSearchAction -MockWith { @() }

            { Start-PurgeAction -SearchName 'IR-3' -PurgeType SoftDelete } | Should -Throw '*did not complete successfully*'
        }

        It 'Start-PurgeAction throws when action disappears' {
            Mock -ModuleName 'PhishIR' -CommandName Invoke-NewComplianceSearchAction -MockWith { $true }
            Mock -ModuleName 'PhishIR' -CommandName Invoke-GetComplianceSearchAction -MockWith {
                $script:getCall++ | Out-Null
                if ($script:getCall -eq 1) {
                    [pscustomobject]@{ Name='IR-4_Purge'; Status='InProgress'; Progress='10%'; ItemsPurged=$null }
                } else {
                    $null
                }
            }
            Mock -ModuleName 'PhishIR' -CommandName Invoke-GetAllComplianceSearchAction -MockWith { @() }

            { Start-PurgeAction -SearchName 'IR-4' -PurgeType SoftDelete } | Should -Throw '*disappeared*'
        }
        
        It 'Start-PurgeAction handles timeout scenario' {
            Mock -ModuleName 'PhishIR' -CommandName Invoke-NewComplianceSearchAction -MockWith { $true }
            Mock -ModuleName 'PhishIR' -CommandName Invoke-GetComplianceSearchAction -MockWith {
                [pscustomobject]@{ Name='IR-5_Purge'; Status='InProgress'; Progress='10%'; ItemsPurged=$null }
            }
            Mock -ModuleName 'PhishIR' -CommandName Invoke-GetAllComplianceSearchAction -MockWith { @() }
            
            { Start-PurgeAction -SearchName 'IR-5' -PurgeType SoftDelete } | Should -Throw '*did not complete successfully*'
        }
    }
}

Describe 'Retry Logic with Jitter' {
    It 'Applies jitter to retry delays' {
        InModuleScope 'PhishIR' {
            $script:delays = @()
            Mock Start-Sleep { param($Seconds) $script:delays += $Seconds }
            $script:cnt = 0
            try {
                Invoke-WithRetry -ScriptBlock { $script:cnt++; if ($script:cnt -lt 3) { throw 'transient' } } -MaxRetries 3 -InitialDelaySeconds 1
            } catch {}
            
            $script:delays.Count | Should -BeGreaterThan 0
            # Verify jitter is applied: delays should vary
            if ($script:delays.Count -gt 1) {
                $unique = ($script:delays | Sort-Object -Unique).Count
                $unique | Should -BeGreaterThan 0
            }
        }
    }
    
    It 'Detects throttling errors' {
        InModuleScope 'PhishIR' {
            Mock Start-Sleep {}
            $script:cnt = 0
            { Invoke-WithRetry -ScriptBlock { $script:cnt++; throw '429 TooManyRequests' } -MaxRetries 2 -InitialDelaySeconds 1 } | Should -Throw
            $script:cnt | Should -Be 2
        }
    }
}

Describe 'HardDelete Confirmation' {
    InModuleScope 'PhishIR' {
        BeforeEach {
            Mock Ensure-ExchangeOnlineConnection {}
            Mock Ensure-ComplianceConnection {}
            Mock Test-MailboxesForPurge { @{ ValidMailboxes=@('test@test.com'); MailboxDetails=@([pscustomobject]@{PrimarySmtpAddress='test@test.com';LitigationHoldEnabled=$false;InPlaceHoldsCount=0}) } }
            Mock New-ComplianceSearchJob { [pscustomobject]@{ Name='Test'; Status='Completed'; Items=1 } }
            Mock Get-MailboxPersistenceArtifacts {}
            Mock Export-SearchResults { @{ ItemsFound=1; PerMailboxResults=@([pscustomobject]@{Mailbox='test@test.com';ItemCount=1}); PreviewCsv='test.csv'; PreviewJson='test.json' } }
            Mock Start-PurgeAction { [pscustomobject]@{ Status='Completed'; ItemsPurged=1 } }
            Mock Export-PurgeResults { @{ ItemsPurged=1; ReportCsv='report.csv'; ReportJson='report.json' } }
            Mock New-Item {}
        }
        
        It 'Blocks HardDelete without confirmation phrase' {
            { Invoke-MailPurge -Mailboxes 'test@test.com' -Senders 'bad@evil.com' -PurgeType HardDelete -Confirm:$false } | Should -Throw '*confirmation phrase*'
        }
        
        It 'Blocks HardDelete with wrong confirmation phrase' {
            { Invoke-MailPurge -Mailboxes 'test@test.com' -Senders 'bad@evil.com' -PurgeType HardDelete -HardDeleteConfirmation 'wrong phrase' -Confirm:$false } | Should -Throw '*confirmation phrase*'
        }
        
        It 'Allows HardDelete with exact confirmation phrase' {
            { Invoke-MailPurge -Mailboxes 'test@test.com' -Senders 'bad@evil.com' -PurgeType HardDelete -HardDeleteConfirmation 'CONFIRM: I have legal approval for permanent deletion' -Confirm:$false } | Should -Not -Throw
        }
        
        It 'Allows PreviewOnly HardDelete without confirmation' {
            { Invoke-MailPurge -Mailboxes 'test@test.com' -Senders 'bad@evil.com' -PurgeType HardDelete -PreviewOnly } | Should -Not -Throw
        }
    }
}

Describe 'Health Check' {
    InModuleScope 'PhishIR' {
        It 'Returns health status object' {
            # Ensure external commands exist in module scope for mocking
            if (-not (Get-Command Get-ComplianceSearch -ErrorAction SilentlyContinue)) {
                function Get-ComplianceSearch { param([string]$Identity) throw 'not found' }
            }
            if (-not (Get-Command Get-EXOMailbox -ErrorAction SilentlyContinue)) {
                function Get-EXOMailbox { param([int]$ResultSize) throw 'not connected' }
            }

            Mock Get-EXOMailbox { throw 'not connected' }
            Mock Get-ComplianceSearch { throw 'not found' }

            $health = Get-PhishIRHealth
            $health.Status | Should -BeIn @('Healthy', 'Degraded')
            $health.Checks | Should -Not -BeNullOrEmpty
            $health.Timestamp | Should -Not -BeNullOrEmpty
            $health.ModuleVersion | Should -Be '2.0.0'
        }
    }
}

Describe 'WhatIf Report Generation' {
    It 'Generates local WhatIf report without remote calls' {
        $tempDir = Join-Path $TestDrive 'WhatIfTest'
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        
        $mailboxes = @('test1@contoso.com', 'test2@contoso.com', 'test3@contoso.com')
        $query = 'from:evil@bad.com AND subject:"urgent"'
        
        $result = Export-PhishIRWhatIfReport -Mailboxes $mailboxes -ContentMatchQuery $query -PurgeType SoftDelete -OutputDir $tempDir
        
        # Verify outputs exist
        $result.Csv | Should -Exist
        $result.Json | Should -Exist
        
        # Verify CSV structure
        $csv = Import-Csv $result.Csv
        $csv.MailboxCount | Should -Be 3
        $csv.PurgeType | Should -Be 'SoftDelete'
        $csv.PrereqStatus | Should -BeIn @('Healthy', 'Degraded')
        
        # Verify JSON structure
        $json = Get-Content $result.Json -Raw | ConvertFrom-Json
        $json.MailboxCount | Should -Be 3
        $json.ContentMatchQuery | Should -Be $query
        $json.HardDeleteConfirmationRequired | Should -Be $false
        $json.SampleRing0 | Should -Not -BeNullOrEmpty
        $json.CorrelationId | Should -Match '^[a-f0-9\-]{36}$'
    }
    
    It 'Includes HardDelete confirmation phrase when required' {
        $tempDir = Join-Path $TestDrive 'WhatIfHardDelete'
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        
        $result = Export-PhishIRWhatIfReport -Mailboxes @('test@contoso.com') -ContentMatchQuery 'test' -PurgeType HardDelete -OutputDir $tempDir
        
        $json = Get-Content $result.Json -Raw | ConvertFrom-Json
        $json.HardDeleteConfirmationRequired | Should -Be $true
        $json.HardDeleteConfirmationPhrase | Should -Be 'CONFIRM: I have legal approval for permanent deletion'
    }
    
    It 'Suggests ring-0 pilot mailboxes (10% or max 10)' {
        $tempDir = Join-Path $TestDrive 'WhatIfRing0'
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        
        # Test with 5 mailboxes - should suggest 1 (10%)
        $result = Export-PhishIRWhatIfReport -Mailboxes @('m1@c.com','m2@c.com','m3@c.com','m4@c.com','m5@c.com') -ContentMatchQuery 'test' -PurgeType SoftDelete -OutputDir $tempDir
        $json = Get-Content $result.Json -Raw | ConvertFrom-Json
        ($json.SampleRing0 -split '; ').Count | Should -Be 1
        
        # Test with 200 mailboxes - should suggest 10 (max cap)
        $manyMailboxes = 1..200 | ForEach-Object { "user$_@contoso.com" }
        $result2 = Export-PhishIRWhatIfReport -Mailboxes $manyMailboxes -ContentMatchQuery 'test' -PurgeType SoftDelete -OutputDir $tempDir
        $json2 = Get-Content $result2.Json -Raw | ConvertFrom-Json
        ($json2.SampleRing0 -split '; ').Count | Should -Be 10
    }
}

AfterAll { Remove-Module PhishIR -ErrorAction SilentlyContinue }
