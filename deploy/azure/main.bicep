// =============================================================================
// Sub2API on Azure - Single VM + Docker Compose
// =============================================================================
// 部署内容：
//   - 虚拟网络 / 子网 / 网络安全组（仅放行 22 / 80 / 443）
//   - 静态公网 IP（带 DNS 标签，得到 <dnsLabel>.<region>.cloudapp.azure.com）
//   - Ubuntu 24.04 LTS 虚拟机（cloud-init 自动安装 Docker + Compose）
//
// 用法：
//   az deployment group create -g <rg> -f main.bicep -p dnsLabel=xxx adminSshPublicKey="ssh-ed25519 ..."
// =============================================================================

@description('资源名称前缀')
param namePrefix string = 'sub2api'

@description('部署区域，默认跟随资源组')
param location string = resourceGroup().location

@description('公网 DNS 标签，最终域名为 <dnsLabel>.<region>.cloudapp.azure.com，需在该区域内全局唯一')
@minLength(3)
@maxLength(50)
param dnsLabel string

@description('VM 登录用户名')
param adminUsername string = 'azureuser'

@description('SSH 公钥内容（~/.ssh/id_ed25519.pub 的完整一行）')
@secure()
param adminSshPublicKey string

@description('VM 规格。Standard_B2s = 2 vCPU / 4 GiB，适合 10 人以内轻量使用')
param vmSize string = 'Standard_B2s'

@description('系统盘大小（GB）')
@minValue(32)
param osDiskSizeGb int = 64

@description('允许 SSH 来源。生产建议改成你的固定出口 IP，例如 203.0.113.7/32')
param sshSourceAddressPrefix string = '*'

var vnetName = '${namePrefix}-vnet'
var subnetName = '${namePrefix}-subnet'
var nsgName = '${namePrefix}-nsg'
var pipName = '${namePrefix}-pip'
var nicName = '${namePrefix}-nic'
var vmName = '${namePrefix}-vm'

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSSH'
        properties: {
          priority: 1001
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: sshSourceAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'AllowHTTP'
        properties: {
          priority: 1002
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        name: 'AllowHTTPS'
        properties: {
          priority: 1003
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.20.0.0/16']
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.20.1.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: pipName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: dnsLabel
    }
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          publicIPAddress: {
            id: pip.id
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: osDiskSizeGb
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
        deleteOption: 'Delete'
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      customData: loadFileAsBase64('cloud-init.yaml')
      linuxConfiguration: {
        disablePasswordAuthentication: true
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
          assessmentMode: 'AutomaticByPlatform'
        }
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

output fqdn string = pip.properties.dnsSettings.fqdn
output publicIp string = pip.properties.ipAddress
output sshCommand string = 'ssh ${adminUsername}@${pip.properties.dnsSettings.fqdn}'
output siteUrl string = 'https://${pip.properties.dnsSettings.fqdn}'
