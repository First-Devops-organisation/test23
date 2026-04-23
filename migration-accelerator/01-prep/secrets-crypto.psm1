<#
.SYNOPSIS
    Shared AES-256-CBC encryption/decryption module for secret migration.
.DESCRIPTION
    Provides Protect-Secret and Unprotect-Secret functions that use AES-256-CBC
    with PBKDF2 key derivation from a passphrase. Encrypted values are wrapped
    in ENC{<base64>} format for easy identification and machine parsing.

    The base64 payload contains: 16-byte salt + 16-byte IV + ciphertext.

    Used by scrub-secrets.ps1 (encrypt before ADO migration) and
    decrypt-secrets.ps1 (decrypt after GitHub migration).
#>

# --- Constants ---
$script:PBKDF2_ITERATIONS = 100000
$script:KEY_SIZE_BYTES    = 32   # AES-256
$script:SALT_SIZE_BYTES   = 16
$script:IV_SIZE_BYTES     = 16   # AES block size
$script:ENC_PREFIX        = 'ENC{'
$script:ENC_SUFFIX        = '}'

function Protect-Secret {
    <#
    .SYNOPSIS
        Encrypts a plaintext string using AES-256-CBC with a passphrase-derived key.
    .PARAMETER Plaintext
        The secret value to encrypt.
    .PARAMETER Passphrase
        The passphrase used to derive the encryption key via PBKDF2.
    .OUTPUTS
        [string] — Encrypted value in the format ENC{<base64>}
    .EXAMPLE
        Protect-Secret -Plaintext "my-api-key-12345" -Passphrase "migration-key"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Plaintext,

        [Parameter(Mandatory = $true)]
        [string]$Passphrase
    )

    # Generate random salt and IV
    $salt = New-Object byte[] $script:SALT_SIZE_BYTES
    $iv   = New-Object byte[] $script:IV_SIZE_BYTES
    $rng  = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($salt)
    $rng.GetBytes($iv)

    # Derive key from passphrase using PBKDF2
    $keyDerivation = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
        $Passphrase, $salt, $script:PBKDF2_ITERATIONS, [System.Security.Cryptography.HashAlgorithmName]::SHA256
    )
    $key = $keyDerivation.GetBytes($script:KEY_SIZE_BYTES)

    # Encrypt using AES-256-CBC
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key     = $key
    $aes.IV      = $iv

    $encryptor    = $aes.CreateEncryptor()
    $plaintextBytes = [System.Text.Encoding]::UTF8.GetBytes($Plaintext)
    $cipherBytes  = $encryptor.TransformFinalBlock($plaintextBytes, 0, $plaintextBytes.Length)

    # Combine salt + IV + ciphertext → base64
    $payload = New-Object byte[] ($salt.Length + $iv.Length + $cipherBytes.Length)
    [Array]::Copy($salt,        0, $payload, 0,                              $salt.Length)
    [Array]::Copy($iv,          0, $payload, $salt.Length,                    $iv.Length)
    [Array]::Copy($cipherBytes, 0, $payload, $salt.Length + $iv.Length,       $cipherBytes.Length)

    $base64 = [Convert]::ToBase64String($payload)

    # Cleanup
    $aes.Dispose()
    $keyDerivation.Dispose()
    $rng.Dispose()

    return "$($script:ENC_PREFIX)$base64$($script:ENC_SUFFIX)"
}

function Unprotect-Secret {
    <#
    .SYNOPSIS
        Decrypts an ENC{<base64>} string back to the original plaintext.
    .PARAMETER EncryptedValue
        The encrypted value in ENC{<base64>} format.
    .PARAMETER Passphrase
        The passphrase used during encryption.
    .OUTPUTS
        [string] — The original plaintext secret.
    .EXAMPLE
        Unprotect-Secret -EncryptedValue "ENC{dGVz...}" -Passphrase "migration-key"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$EncryptedValue,

        [Parameter(Mandatory = $true)]
        [string]$Passphrase
    )

    # Strip ENC{...} wrapper
    if ($EncryptedValue.StartsWith($script:ENC_PREFIX) -and $EncryptedValue.EndsWith($script:ENC_SUFFIX)) {
        $base64 = $EncryptedValue.Substring(
            $script:ENC_PREFIX.Length,
            $EncryptedValue.Length - $script:ENC_PREFIX.Length - $script:ENC_SUFFIX.Length
        )
    }
    else {
        throw "Invalid encrypted value format. Expected ENC{<base64>}, got: $($EncryptedValue.Substring(0, [Math]::Min(30, $EncryptedValue.Length)))..."
    }

    # Decode base64 payload
    $payload = [Convert]::FromBase64String($base64)

    if ($payload.Length -lt ($script:SALT_SIZE_BYTES + $script:IV_SIZE_BYTES + 1)) {
        throw "Encrypted payload is too short to contain salt + IV + ciphertext."
    }

    # Extract salt, IV, ciphertext
    $salt = New-Object byte[] $script:SALT_SIZE_BYTES
    $iv   = New-Object byte[] $script:IV_SIZE_BYTES
    $cipherLength = $payload.Length - $script:SALT_SIZE_BYTES - $script:IV_SIZE_BYTES
    $cipherBytes  = New-Object byte[] $cipherLength

    [Array]::Copy($payload, 0,                                              $salt,        0, $script:SALT_SIZE_BYTES)
    [Array]::Copy($payload, $script:SALT_SIZE_BYTES,                        $iv,          0, $script:IV_SIZE_BYTES)
    [Array]::Copy($payload, $script:SALT_SIZE_BYTES + $script:IV_SIZE_BYTES, $cipherBytes, 0, $cipherLength)

    # Derive key from passphrase using same PBKDF2 parameters
    $keyDerivation = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
        $Passphrase, $salt, $script:PBKDF2_ITERATIONS, [System.Security.Cryptography.HashAlgorithmName]::SHA256
    )
    $key = $keyDerivation.GetBytes($script:KEY_SIZE_BYTES)

    # Decrypt using AES-256-CBC
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key     = $key
    $aes.IV      = $iv

    $decryptor     = $aes.CreateDecryptor()
    $plaintextBytes = $decryptor.TransformFinalBlock($cipherBytes, 0, $cipherBytes.Length)

    # Cleanup
    $aes.Dispose()
    $keyDerivation.Dispose()

    return [System.Text.Encoding]::UTF8.GetString($plaintextBytes)
}

function Test-EncryptedValue {
    <#
    .SYNOPSIS
        Tests whether a string matches the ENC{<base64>} pattern.
    .PARAMETER Value
        The string to test.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return ($Value -match 'ENC\{[A-Za-z0-9+/=]+\}')
}

function Get-EncryptedPattern {
    <#
    .SYNOPSIS
        Returns the regex pattern used to match ENC{<base64>} tokens in file content.
    .OUTPUTS
        [string] — Regex pattern with one capture group for the full ENC{...} token.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return 'ENC\{[A-Za-z0-9+/=]+\}'
}

Export-ModuleMember -Function Protect-Secret, Unprotect-Secret, Test-EncryptedValue, Get-EncryptedPattern
