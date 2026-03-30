BeforeAll {
    $ModulePath = "$PSScriptRoot\..\..\Scripts\Modules\SafeStorageAccess.psm1"
    Import-Module $ModulePath -Force
}

Describe "SafeStorageAccess Module" {
    Context "Get-PartitionSafe" {
        It "Should return synthetic partition object when Get-Partition cmdlet is unavailable" {
            Mock -CommandName Get-Command -ModuleName SafeStorageAccess -MockWith { $null }

            $result = Get-PartitionSafe -DiskNumber 0 -PartitionNumber 4

            $result | Should -Not -BeNullOrEmpty
            $result.HealthStatus | Should -Be 'NotChecked'
            $result.OperationalStatus | Should -Be 'NotChecked'
            $result.DiskNumber | Should -Be 0
            $result.PartitionNumber | Should -Be 4
        }

        It "Should return all partitions for disk when cmdlet exists" {
            Mock -CommandName Get-Command -ModuleName SafeStorageAccess -MockWith { @{ Name = 'Get-Partition' } }
            Mock -CommandName Get-Partition -ModuleName SafeStorageAccess -MockWith {
                @(
                    [pscustomobject]@{ PartitionNumber = 1; Type = 'Basic'; Size = 100MB; HealthStatus = 'Healthy'; OperationalStatus = 'Online'; Offset = 0 }
                    [pscustomobject]@{ PartitionNumber = 2; Type = 'Recovery'; Size = 800MB; HealthStatus = 'Healthy'; OperationalStatus = 'Online'; Offset = 100MB }
                )
            }

            $result = Get-PartitionSafe -DiskNumber 0

            $result | Should -Not -BeNullOrEmpty
            @($result).Count | Should -Be 2
            $result[1].PartitionNumber | Should -Be 2
        }
    }

    Context "Get-DiskSafe" {
        It "Should return synthetic disk object when Get-Disk cmdlet is unavailable" {
            Mock -CommandName Get-Command -ModuleName SafeStorageAccess -MockWith { $null }

            $result = Get-DiskSafe -Number 0

            $result | Should -Not -BeNullOrEmpty
            $result.HealthStatus | Should -Be 'NotChecked'
            $result.OperationalStatus | Should -Be 'NotChecked'
            $result.Number | Should -Be 0
        }

        It "Should normalize blank health properties to NotChecked" {
            Mock -CommandName Get-Command -ModuleName SafeStorageAccess -MockWith { @{ Name = 'Get-Disk' } }
            Mock -CommandName Get-Disk -ModuleName SafeStorageAccess -MockWith {
                [pscustomobject]@{ Number = 0; HealthStatus = ''; OperationalStatus = $null; Size = 100GB; FriendlyName = 'Disk0' }
            }

            $result = Get-DiskSafe -Number 0

            $result.HealthStatus | Should -Be 'NotChecked'
            $result.OperationalStatus | Should -Be 'NotChecked'
        }
    }
}

AfterAll {
    Remove-Module SafeStorageAccess -Force -ErrorAction SilentlyContinue
}
