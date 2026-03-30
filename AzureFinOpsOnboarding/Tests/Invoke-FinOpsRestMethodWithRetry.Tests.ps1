Describe 'Invoke-FinOpsRestMethodWithRetry' {
    BeforeAll {
        Import-Module "$PSScriptRoot/../AzureFinOpsOnboarding.psd1" -Force
    }

    Context 'Successful call on first attempt' {
        It 'Should return result without retries' {
            InModuleScope AzureFinOpsOnboarding {
                Mock Invoke-RestMethod {
                    return @{ status = 'success'; data = 'test' }
                }

                $result = Invoke-FinOpsRestMethodWithRetry -Uri 'https://api.example.com/test' -Method Get
                
                $result.status | Should -Be 'success'
                $result.data | Should -Be 'test'
                Assert-MockCalled Invoke-RestMethod -Exactly 1
            }
        }
    }

    Context 'Transient failure with retry' {
        It 'Should retry on 429 status code and succeed' {
            InModuleScope AzureFinOpsOnboarding {
                $script:callCount = 0
                Mock Invoke-RestMethod {
                    $script:callCount++
                    if ($script:callCount -eq 1) {
                        $response = [PSCustomObject]@{
                            StatusCode = 429
                        }
                        $exception = New-Object System.Net.WebException('Too Many Requests')
                        $exception | Add-Member -MemberType NoteProperty -Name Response -Value $response -Force
                        throw $exception
                    }
                    return @{ status = 'success' }
                }
                Mock Start-Sleep { }

                $result = Invoke-FinOpsRestMethodWithRetry -Uri 'https://api.example.com/test' -Method Get -MaxRetries 3
                
                $result.status | Should -Be 'success'
                Assert-MockCalled Invoke-RestMethod -Exactly 2
                Assert-MockCalled Start-Sleep -Exactly 1
            }
        }

        It 'Should retry on 503 status code' {
            InModuleScope AzureFinOpsOnboarding {
                $script:callCount = 0
                Mock Invoke-RestMethod {
                    $script:callCount++
                    if ($script:callCount -le 2) {
                        $response = [PSCustomObject]@{
                            StatusCode = 503
                        }
                        $exception = New-Object System.Net.WebException('Service Unavailable')
                        $exception | Add-Member -MemberType NoteProperty -Name Response -Value $response -Force
                        throw $exception
                    }
                    return @{ status = 'success' }
                }
                Mock Start-Sleep { }

                $result = Invoke-FinOpsRestMethodWithRetry -Uri 'https://api.example.com/test' -Method Get -MaxRetries 3
                
                $result.status | Should -Be 'success'
                Assert-MockCalled Invoke-RestMethod -Exactly 3
                Assert-MockCalled Start-Sleep -Exactly 2
            }
        }

        It 'Should retry on network timeout' {
            InModuleScope AzureFinOpsOnboarding {
                $script:callCount = 0
                Mock Invoke-RestMethod {
                    $script:callCount++
                    if ($script:callCount -eq 1) {
                        throw [System.Net.WebException]::new('The operation has timed out')
                    }
                    return @{ status = 'success' }
                }
                Mock Start-Sleep { }

                $result = Invoke-FinOpsRestMethodWithRetry -Uri 'https://api.example.com/test' -Method Get -MaxRetries 3
                
                $result.status | Should -Be 'success'
                Assert-MockCalled Invoke-RestMethod -Exactly 2
            }
        }
    }

    Context 'Non-retryable errors' {
        It 'Should not retry on 404 status code' {
            InModuleScope AzureFinOpsOnboarding {
                Mock Invoke-RestMethod {
                    $response = [PSCustomObject]@{
                        StatusCode = 404
                    }
                    $exception = New-Object System.Net.WebException('Not Found')
                    $exception | Add-Member -MemberType NoteProperty -Name Response -Value $response -Force
                    throw $exception
                }
                Mock Start-Sleep { }

                { Invoke-FinOpsRestMethodWithRetry -Uri 'https://api.example.com/test' -Method Get -MaxRetries 3 } | Should -Throw
                
                Assert-MockCalled Invoke-RestMethod -Exactly 1
                Assert-MockCalled Start-Sleep -Exactly 0
            }
        }

        It 'Should not retry on 401 status code' {
            InModuleScope AzureFinOpsOnboarding {
                Mock Invoke-RestMethod {
                    $response = [PSCustomObject]@{
                        StatusCode = 401
                    }
                    $exception = New-Object System.Net.WebException('Unauthorized')
                    $exception | Add-Member -MemberType NoteProperty -Name Response -Value $response -Force
                    throw $exception
                }
                Mock Start-Sleep { }

                { Invoke-FinOpsRestMethodWithRetry -Uri 'https://api.example.com/test' -Method Get -MaxRetries 3 } | Should -Throw
                
                Assert-MockCalled Invoke-RestMethod -Exactly 1
                Assert-MockCalled Start-Sleep -Exactly 0
            }
        }
    }

    Context 'Max retries exceeded' {
        It 'Should throw after max retries' {
            InModuleScope AzureFinOpsOnboarding {
                Mock Invoke-RestMethod {
                    $response = [PSCustomObject]@{
                        StatusCode = 503
                    }
                    $exception = New-Object System.Net.WebException('Service Unavailable')
                    $exception | Add-Member -MemberType NoteProperty -Name Response -Value $response -Force
                    throw $exception
                }
                Mock Start-Sleep { }

                { Invoke-FinOpsRestMethodWithRetry -Uri 'https://api.example.com/test' -Method Get -MaxRetries 2 } | Should -Throw
                
                Assert-MockCalled Invoke-RestMethod -Exactly 3
                Assert-MockCalled Start-Sleep -Exactly 2
            }
        }
    }

    Context 'Exponential backoff' {
        It 'Should apply exponential backoff delays' {
            InModuleScope AzureFinOpsOnboarding {
                $script:delays = @()
                Mock Invoke-RestMethod {
                    $response = [PSCustomObject]@{
                        StatusCode = 429
                    }
                    $exception = New-Object System.Net.WebException('Too Many Requests')
                    $exception | Add-Member -MemberType NoteProperty -Name Response -Value $response -Force
                    throw $exception
                }
                Mock Start-Sleep {
                    param($Seconds)
                    $script:delays += $Seconds
                }

                { Invoke-FinOpsRestMethodWithRetry -Uri 'https://api.example.com/test' -Method Get -MaxRetries 3 -InitialDelaySeconds 2 } | Should -Throw
                
                # With MaxRetries=3: initial attempt fails, then retry 3 times (delays: 2, 4, 8)
                $script:delays.Count | Should -Be 3
                $script:delays[0] | Should -Be 2
                $script:delays[1] | Should -Be 4
                $script:delays[2] | Should -Be 8
            }
        }
    }

    Context 'HTTP methods and parameters' {
        It 'Should support POST with body' {
            InModuleScope AzureFinOpsOnboarding {
                $capturedParams = $null
                Mock Invoke-RestMethod {
                    param($Uri, $Method, $Body, $ContentType, $Headers, $TimeoutSec, $ErrorAction)
                    $script:capturedParams = @{
                        Uri = $Uri
                        Method = $Method
                        Body = $Body
                        ContentType = $ContentType
                    }
                    return @{ status = 'created' }
                }

                $body = '{"key":"value"}'
                $result = Invoke-FinOpsRestMethodWithRetry -Uri 'https://api.example.com/test' -Method Post -Body $body -ContentType 'application/json'
                
                $result.status | Should -Be 'created'
                $script:capturedParams.Method | Should -Be 'Post'
                $script:capturedParams.Body | Should -Be $body
                $script:capturedParams.ContentType | Should -Be 'application/json'
            }
        }

        It 'Should support custom headers' {
            InModuleScope AzureFinOpsOnboarding {
                $capturedHeaders = $null
                Mock Invoke-RestMethod {
                    param($Uri, $Method, $Headers, $TimeoutSec, $ErrorAction)
                    $script:capturedHeaders = $Headers
                    return @{ status = 'success' }
                }

                $headers = @{ 'Authorization' = 'Bearer token123'; 'Custom-Header' = 'value' }
                Invoke-FinOpsRestMethodWithRetry -Uri 'https://api.example.com/test' -Method Get -Headers $headers
                
                $script:capturedHeaders['Authorization'] | Should -Be 'Bearer token123'
                $script:capturedHeaders['Custom-Header'] | Should -Be 'value'
            }
        }
    }
}
