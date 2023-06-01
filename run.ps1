class ImageImportRequestProcessor {
    Import([ImageImportRequest] $Request) {
        $FunctionName = "ImageImportRequestProcessor.Import"

        try {
            $SourceImageExists = $this.CheckSourceImage($Request)
            $TargetImageExists = $this.CheckTargetImage($Request)

            if (!$SourceImageExists ) {
                Write-PSFMessage -Level Important -Message "SourceImge: '$($Request.GetSourceImageTagDesc())' does not exist. Skipping." -Tag 'Info' -FunctionName $FunctionName
                return
            }

            if ($TargetImageExists -and ($Request.Mode -eq "NoForce")) {
                Write-PSFMessage -Level Important -Message "Image: '$($Request.GetTargetImageTag())' already exists in Repository: '$($Request.Registryname)'." -Tag 'Info' -FunctionName $FunctionName
                Write-PSFMessage -Level Important -Message "Image can be re-imported using '-Mode Force'." -Tag 'Info' -FunctionName $FunctionName
                Write-PSFMessage -Level Important -Message "Exiting." -Tag 'Info' -FunctionName $FunctionName
            }
            else {
                $Method = If ($TargetImageExists -and ($Request.Mode -eq "Force")) { "re-import" } Else { "import" }

                Write-PSFMessage -Level Important -Message "Starting to ${Method} image." -Tag 'Info' -FunctionName $FunctionName

                if ($Request.Mode -eq "NoForce") {
                    Write-PSFMessage -Level Important -Message `
                        "Parameter: 'Mode' set to 'NoForce'. This process will fail if image already exists." `
                        -Tag 'Info' -FunctionName $FunctionName
                }

                $this.ExecuteTask($Request)

                Write-PSFMessage -Level Important -Message "Successfully ${Method}ed image." -Tag 'Success' -FunctionName $FunctionName
            }
        }
        catch {
            Write-PSFMessage -Level Error -Message 'Error importing image.' -Tag 'Failure' -ErrorRecord $_ -FunctionName $FunctionName
            $PSCmdlet.ThrowTerminatingError($PSItem)
        }
    }
}

class ImageImportRequestArtifactoryToACRProcessor : ImageImportRequestProcessor {
    [string]$KeyvaultName
    [string]$Username
    [string]$SecretName
    [string]$ApiKey
    ImageImportRequestArtifactoryToACRProcessor(
        [string]$KeyvaultName,
        [string]$Username,
        [string]$SecretName,
        [string]$ApiKey) {
        $this.KeyvaultName = $KeyvaultName
        $this.Username = $Username
        $this.SecretName = $SecretName
        $this.ApiKey = $ApiKey
    }

    ExecuteTask([ImageImportRequest] $Request) {
        Import-AzContainerRegistryImage `
            -SourceRegistryUri $Request.SourceRegistryUri `
            -SourceImage $Request.GetSourceImageTag() `
            -ResourceGroupName $Request.ResourceGroupName `
            -RegistryName $Request.RegistryName `
            -TargetTag $Request.GetTargetImageTag() `
            -Mode $Request.Mode `
            -ErrorAction Stop `
            -Username (Get-AzKeyVaultSecret -VaultName $this.KeyvaultName -Name $this.Username -AsPlainText) `
            -Password (Get-AzKeyVaultSecret -VaultName $this.KeyvaultName -Name $this.SecretName -AsPlainText)
    }
    [bool] CheckSourceImage([ImageImportRequest] $Request) {
        return Find-JFrog-Image `
            -RegistryUri $Request.SourceRegistryUri `
            -Repository $Request.SourceRepo `
            -Image $Request.SourceImage `
            -Tag $Request.SourceTag `
            -KeyvaultName $this.KeyvaultName `
            -SecretName $this.ApiKey
    }

    [bool] CheckTargetImage([ImageImportRequest] $Request) {
        return Find-ACR-Image `
            -RegistryName $Request.RegistryName `
            -Image $Request.TargetImage `
            -Tag $Request.TargetTag
    }
}

class ImageImportRequest {
    [string]$SourceRepo
    [string]$SourceImage
    [string]$SourceTag
    [string]$ResourceGroupName
    [string]$RegistryName
    [string]$TargetImage
    [string]$TargetTag
    [ValidateSet('NoForce', 'Force')] # TODO : ENUM
    [string]$Mode = "NoForce"
    [ValidateSet('Re-Import', 'Import')] # TODO : ENUM
    [string]$ImportType = "Import"

    [ContainersRegistryTypes] $SourceRegistryType
    [ContainersRegistryTypes] $TargetRegistryType

    [string] GetSourceImageTag() { return "$($this.SourceRepo)/$($this.SourceImage):$($this.SourceTag)" } ## refactor
    [string] GetTargetImageTag() { return "$($this.TargetImage):$($this.TargetTag)" }  ## refactor
}

class ImageImportRequestExternalToACR : ImageImportRequest {
    [string]$SourceRegistryUri
    ImageImportRequestExternalToACR([string]$SourceRegistryUri,
        [string]$SourceRepo,
        [string]$SourceImage,
        [string]$SourceTag,
        [string]$ResourceGroupName,
        [string]$RegistryName,
        [string]$TargetImage,
        [string]$TargetTag) {
        $this.SourceRegistryUri = $SourceRegistryUri
        $this.SourceRepo = $SourceRepo
        $this.SourceImage = $SourceImage
        $this.SourceTag = $SourceTag
        $this.ResourceGroupName = $ResourceGroupName
        $this.RegistryName = $RegistryName
        $this.TargetImage = $TargetImage
        $this.TargetTag = $TargetTag
        $this.SourceRegistryType = [ContainersRegistryTypes]::artifactory
        $this.TargetRegistryType = [ContainersRegistryTypes]::acr
    }
    [string] GetSourceImageTagDesc() { return "$($this.SourceRegistryUri)/$($this.SourceRepo)/$($this.SourceImage):$($this.SourceTag)" }
}

class ImageImportRequestProcessorResolver {
    [ImageImportRequestProcessor] static Resolve([ImageImportRequest]$Request) {
        $processor = $null
        if ($Request -is [ImageImportRequestExternalToACR]) {
            $processor = [ImageImportRequestArtifactoryToACRProcessor]::new("kvpowershell", "igmusername", "igmtoken", "igmapikey")
        }
        return $processor
    }
}

enum ContainersRegistryTypes {
    unknown
    acr = 10
    artifactory = 20
    docker = 30
}

function Find-ACR-Image {
    [CmdletBinding()]
    [OutputType([Boolean])]
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $RegistryName,
        [Parameter(Mandatory = $true)]
        [string]
        $Image,
        [Parameter(Mandatory = $true)]
        [string]
        $Tag
    )
    process {
        try {
            Write-PSFMessage -Level Important -Message "Checking for existing image '${Image}:${Tag}'." -Tag 'Info'
            #TODO: complete all level check
            $RegistryResult = Get-AzContainerRegistryRepository -RegistryName $RegistryName
            
            if (!($RegistryResult -contains $Image)) { return $false }
                
            $TagResult = Get-AzContainerRegistryTag -RegistryName $RegistryName -RepositoryName $Image -ErrorAction Stop
            $TagResult.Tags.Name -contains $Tag
        }
        catch {
            Write-PSFMessage -Level Error -Message "Error checking for existing image '${Image}:${Tag}'." -Tag 'Failure' -ErrorRecord $_
            $PSCmdlet.ThrowTerminatingError($PSItem)
        }
    }
}

function Find-JFrog-Image {
    [CmdletBinding()]
    [OutputType([Boolean])]
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $RegistryUri,
        [Parameter(Mandatory = $true)]
        [string]
        $Repository,
        [Parameter(Mandatory = $true)]
        [string]
        $Image,
        [Parameter(Mandatory = $true)]
        [string]
        $Tag,
        [Parameter(Mandatory = $true)]
        [string]
        $KeyvaultName,
        [Parameter(Mandatory = $true)]
        [string]
        $SecretName
    )
    process {
        $Descriptor = "${RegistryUri}/${Repository}/${Image}:${Tag}"

        Write-PSFMessage -Level Important -Message "Checking for existing image '$Descriptor'." -Tag 'Info'

        $RootURI = "https://$($RegistryUri)/artifactory/api/docker/$($Repository)/v2"
        $Headers = @{ 'X-JFrog-Art-Api' = (Get-AzKeyVaultSecret -VaultName $KeyvaultName -Name $SecretName -AsPlainText) }

        try {
            $ImageResult = Invoke-RestMethod -Uri "$RootURI/_catalog" -Headers $Headers -ErrorAction Stop
            if (!($ImageResult.repositories -contains $Image)) {
                Write-PSFMessage -Level Important -Message "Repositoy: '${RegistryUri}/${Repository}/${image}' not found."
            }
        }
        catch {
            if($PSItem.Exception.Response.StatusCode -eq 'NotFound') {
                Write-PSFMessage -Level Important -Message "Repositoy: '${RegistryUri}/${Repository}' not found."
                return $false
            } else {
                Write-PSFMessage -Level Error -Message "Error checking for existing image '$Descriptor'." -Tag 'Failure' -ErrorRecord $_
                $PSCmdlet.ThrowTerminatingError($PSItem)
            }
        }

        try {
            $TagResult = Invoke-RestMethod -Uri "$RootURI/$($Image)/tags/list" -Headers $Headers
            $TagResult.tags -contains $Tag
        }
        catch {
            if($PSItem.Exception.Response.StatusCode -eq 'NotFound') {
                Write-PSFMessage -Level Important -Message "Image: '${RegistryUri}/${Repository}/${Image}' not found."
                return $false
            } else {
                Write-PSFMessage -Level Error -Message "Error checking for existing image '$Descriptor'." -Tag 'Failure' -ErrorRecord $_
                $PSCmdlet.ThrowTerminatingError($PSItem)
            }
        }
    }
}

function Get-ACR-Import-Requests {
    [CmdletBinding()]
    [OutputType([ImageImportRequest])]
    param
    (
        [Parameter(Mandatory, ValueFromPipeline)]
        [hashtable[]]
        $Request
    )
    $importRequest = [ImageImportRequestExternalToACR]::new(
        $Request.SourceRegistryUri,
        $Request.SourceRepo,
        $Request.SourceImage,
        $Request.SourceTag,
        $Request.ResourceGroupName,
        $Request.RegistryName,
        $Request.TargetImage,
        $Request.TargetTag
    )
    $importRequest.Mode = "Force"
    $importRequest
}

function Action-ACR-Import-Requests {
    [CmdletBinding()]
    [OutputType([ImageImportRequest])]
    param
    (
        [Parameter(Mandatory, ValueFromPipeline)]
        [ImageImportRequest]
        $Request
    )
   
    $Processor = [ImageImportRequestProcessorResolver]::Resolve($Request)
    $Processor.Import($Request)
}

function Run {
    [CmdletBinding()]
    [OutputType([Boolean])]
    param()

    process {
        try {
            Write-PSFMessage -Level Important -Message "Processing" -Tag 'Info'

            # $Request = @{
            #     SourceRegistryUri = 'docker.io'
            #     SourceRepo        = 'library'
            #     SourceImage       = 'busybox'
            #     SourceTag         = 'latest'
            #     ResourceGroupName = 'rg-k8s-helm'
            #     RegistryName      = 'acrk8shelmtest'
            #     TargetImage       = 'busyboxadditional'
            #     TargetTag         = '12345673456788'
            # }

            $Request = @{
                SourceRegistryUri = 'mickstev.jfrog.io'
                SourceRepo        = 'repotest-additional-docker' #TODO add target repo path
                SourceImage       = 'hello-world'
                SourceTag         = '1.0.1' # TODO : query from the source repository
                ResourceGroupName = 'rg-k8s-helm'
                RegistryName      = 'acrk8shelmtest'
                TargetImage       = 'hello-world'
                TargetTag         = '1.0.22'
            }

            Get-ACR-Import-Requests -Request $Request |
            Action-ACR-Import-Requests
        }
        catch {
            Write-PSFMessage -Level Error -Message "Error" -Tag 'Failure' -ErrorRecord $_
            $PSCmdlet.ThrowTerminatingError($PSItem)
        }
    }
}

Run