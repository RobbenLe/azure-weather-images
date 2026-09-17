param location string = resourceGroup().location

@description('Region for the Container Apps environment and its workloads. Differs from `location` because Sweden Central only provisions express environments for this subscription, and express environments do not support Container Apps Jobs.')
param environmentLocation string = location

//Now Bicep know prefix must be minimum 3 
@minLength(3)
@maxLength(22)
param namePrefix string

@description('Tag of the three container images to deploy')
param imageTag string = 'v3'

var rgTags = resourceGroup().?tags ?? {}

var storageAccountName = 'st${namePrefix}'          // stweatherimg707875
var acrName = 'acr${namePrefix}'                    // acrweatherimg707875
var identityName = 'id-weatherimages-${namePrefix}'
var logAnalyticsName = 'log-weatherimages-${namePrefix}'
var environmentName = 'cae-weatherimages'
var apiAppName = 'ca-weatherimages-api'
var fetchWeatherJobName = 'job-weatherimages-fetchweather'
var processImageJobName = 'job-weatherimages-processimage'
var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'

// ---------------------------------------------------------------- Storage
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: rgTags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: true // TODO: set to false once SAS tokens are used (Could requirement)
    minimumTlsVersion: 'TLS1_2'
    accessTier: 'Hot'
    publicNetworkAccess: 'Enabled'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource imagesContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'images'
  properties: {
    publicAccess: 'Blob' // TODO: 'None' once SAS tokens are used (Could requirement)
  }
}

// ---------------------------------------------------------------- Queues
resource queueService 'Microsoft.Storage/storageAccounts/queueServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource startJobQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueService
  name: 'start-job'
}

resource processImageQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueService
  name: 'process-image'
}

// ---------------------------------------------------------------- Registry
resource pullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: rgTags
}

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  tags: rgTags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true // TODO: false once the apps pull with pullIdentity
    publicNetworkAccess: 'Enabled'
  }
}

resource acrPullRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '7f951dda-4ed3-4680-a7ca-43fe172d538d' // AcrPull
  scope: subscription()
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerRegistry.id, pullIdentity.id, 'AcrPull')
  scope: containerRegistry
  properties: {
    roleDefinitionId: acrPullRole.id
    principalId: pullIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------- Container Apps environment
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsName
  location: location
  tags: rgTags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
  }
}

// Created by deploy.ps1 with:
//   az containerapp env create ... --enable-workload-profiles true
// ARM/Bicep has no equivalent flag and templates create "express" environments,
// which do not support Container Apps Jobs. Bicep only references it here.
resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: environmentName
}

// ---------------------------------------------------------------- API (Container App)
resource apiApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: apiAppName
  location: environmentLocation
  tags: rgTags
  properties: {
    managedEnvironmentId: managedEnvironment.id
    workloadProfileName: 'Consumption' 
    configuration: {
      ingress: {
        external: true
        targetPort: 8080
        allowInsecure: false
      }
      secrets: [
        {
          name: 'storage-connection'
          value: storageConnectionString
        }
        {
          name: 'acr-password'
          value: containerRegistry.listCredentials().passwords[0].value
        }
      ]
      registries: [
        {
          server: containerRegistry.properties.loginServer
          username: containerRegistry.listCredentials().username
          passwordSecretRef: 'acr-password'
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'api'
          image: '${containerRegistry.properties.loginServer}/weatherimages-api:${imageTag}'
          env: [
            {
              name: 'STORAGE_CONNECTION'
              secretRef: 'storage-connection'
            }
          ]
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 3
      }
    }
  }
}

// ---------------------------------------------------------------- Job 1 (fetch weather)
resource fetchWeatherJob 'Microsoft.App/jobs@2024-03-01' = {
  name: fetchWeatherJobName
  location: environmentLocation
  tags: rgTags
  properties: {
    environmentId: managedEnvironment.id
    workloadProfileName: 'Consumption' 
    configuration: {
      triggerType: 'Event'
      replicaTimeout: 600
      replicaRetryLimit: 1
      secrets: [
        {
          name: 'storage-connection'
          value: storageConnectionString
        }
        {
          name: 'acr-password'
          value: containerRegistry.listCredentials().passwords[0].value
        }
      ]
      registries: [
        {
          server: containerRegistry.properties.loginServer
          username: containerRegistry.listCredentials().username
          passwordSecretRef: 'acr-password'
        }
      ]
      eventTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
        scale: {
          minExecutions: 0
          maxExecutions: 1
          pollingInterval: 30
          rules: [
            {
              name: 'start-job-queue-rule'
              type: 'azure-queue'
              metadata: {
                accountName: storageAccount.name
                queueName: 'start-job'
                queueLength: '1'
              }
              auth: [
                {
                  secretRef: 'storage-connection'
                  triggerParameter: 'connection'
                }
              ]
            }
          ]
        }
      }
    }
    template: {
      containers: [
        {
          name: 'fetchweather'
          image: '${containerRegistry.properties.loginServer}/weatherimages-fetchweather:${imageTag}'
          env: [
            {
              name: 'STORAGE_CONNECTION'
              secretRef: 'storage-connection'
            }
          ]
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
        }
      ]
    }
  }
}

// ---------------------------------------------------------------- Job 2 (process image, fan-out)
resource processImageJob 'Microsoft.App/jobs@2024-03-01' = {
  name: processImageJobName
  location: environmentLocation
  tags: rgTags
  properties: {
    environmentId: managedEnvironment.id
    workloadProfileName: 'Consumption' 
    configuration: {
      triggerType: 'Event'
      replicaTimeout: 1800
      replicaRetryLimit: 1
      secrets: [
        {
          name: 'storage-connection'
          value: storageConnectionString
        }
        {
          name: 'acr-password'
          value: containerRegistry.listCredentials().passwords[0].value
        }
      ]
      registries: [
        {
          server: containerRegistry.properties.loginServer
          username: containerRegistry.listCredentials().username
          passwordSecretRef: 'acr-password'
        }
      ]
      eventTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
        scale: {
          minExecutions: 0
          maxExecutions: 10
          pollingInterval: 30
          rules: [
            {
              name: 'process-image-queue-rule'
              type: 'azure-queue'
              metadata: {
                accountName: storageAccount.name
                queueName: 'process-image'
                queueLength: '5'
              }
              auth: [
                {
                  secretRef: 'storage-connection'
                  triggerParameter: 'connection'
                }
              ]
            }
          ]
        }
      }
    }
    template: {
      containers: [
        {
          name: 'processimage'
          image: '${containerRegistry.properties.loginServer}/weatherimages-processimage:${imageTag}'
          env: [
            {
              name: 'STORAGE_CONNECTION'
              secretRef: 'storage-connection'
            }
          ]
          resources: {
            cpu: json('0.5')
            memory: '1.0Gi'
          }
        }
      ]
    }
  }
}

// ---------------------------------------------------------------- Outputs
output storageAccountName string = storageAccount.name
output acrLoginServer string = containerRegistry.properties.loginServer
output pullIdentityId string = pullIdentity.id
output environmentId string = managedEnvironment.id
output apiFqdn string = apiApp.properties.configuration.ingress.fqdn
