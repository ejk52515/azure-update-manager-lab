variable "location"            { type = string }
variable "resource_group_name" { type = string }
variable "subnet_id"           { type = string }
variable "admin_username"      { type = string }
variable "admin_password" {
  type      = string
  sensitive = true
}
variable "domain_name"    { type = string }
variable "domain_netbios" { type = string }

# Public IPs — Static so addresses are reserved immediately and do not change
resource "azurerm_public_ip" "dc01" {
  name                = "pip-dc01"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}
resource "azurerm_public_ip" "ws01" {
  name                = "pip-ws01"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}
resource "azurerm_public_ip" "ws02" {
  name                = "pip-ws02"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# DC01 NIC — STATIC IP 10.0.1.4 so WS01/WS02 DNS pointing here never breaks
resource "azurerm_network_interface" "dc01" {
  name                = "nic-dc01"
  location            = var.location
  resource_group_name = var.resource_group_name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.1.4"
    public_ip_address_id          = azurerm_public_ip.dc01.id
  }
}
resource "azurerm_network_interface" "ws01" {
  name                = "nic-ws01"
  location            = var.location
  resource_group_name = var.resource_group_name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.ws01.id
  }
}
resource "azurerm_network_interface" "ws02" {
  name                = "nic-ws02"
  location            = var.location
  resource_group_name = var.resource_group_name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.ws02.id
  }
}

locals {
  img = {
    pub   = "MicrosoftWindowsServer"
    offer = "WindowsServer"
    sku   = "2022-Datacenter"
    ver   = "latest"
  }
}

# All three VMs use Windows Server 2022 Datacenter, Standard_DS1_v2 size (quota-adjusted from B2s)
resource "azurerm_windows_virtual_machine" "dc01" {
  name                  = "DC01"
  location              = var.location
  resource_group_name   = var.resource_group_name
  size = "Standard_DS1_v2"
  patch_mode = "AutomaticByPlatform"
  bypass_platform_safety_checks_on_user_schedule_enabled = true
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.dc01.id]
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
  source_image_reference {
    publisher = local.img.pub
    offer     = local.img.offer
    sku       = local.img.sku
    version   = local.img.ver
  }
}
resource "azurerm_windows_virtual_machine" "ws01" {
  name                  = "WS01"
  location              = var.location
  resource_group_name   = var.resource_group_name
  size = "Standard_DS1_v2"
  patch_mode = "AutomaticByPlatform"
  bypass_platform_safety_checks_on_user_schedule_enabled = true
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.ws01.id]
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
  source_image_reference {
    publisher = local.img.pub
    offer     = local.img.offer
    sku       = local.img.sku
    version   = local.img.ver
  }
}
resource "azurerm_windows_virtual_machine" "ws02" {
  name                  = "WS02"
  location              = var.location
  resource_group_name   = var.resource_group_name
  size = "Standard_DS1_v2"
  patch_mode = "AutomaticByPlatform"
  bypass_platform_safety_checks_on_user_schedule_enabled = true
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.ws02.id]
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
  source_image_reference {
    publisher = local.img.pub
    offer     = local.img.offer
    sku       = local.img.sku
    version   = local.img.ver
  }
}

# DC01: promote to Domain Controller via CustomScriptExtension.
# LAB ONLY: DSRM password is hardcoded. Never do this in production.
resource "azurerm_virtual_machine_extension" "setup_dc" {
  name                 = "SetupDC"
  virtual_machine_id   = azurerm_windows_virtual_machine.dc01.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"
  settings = jsonencode({ commandToExecute = join(" ", [
    "powershell -ExecutionPolicy Unrestricted -Command",
    "\"Install-WindowsFeature AD-Domain-Services -IncludeManagementTools;",
    "Import-Module ADDSDeployment;",
    "Install-ADDSForest -DomainName '${var.domain_name}'",
    "-DomainNetBiosName '${var.domain_netbios}'",
    "-SafeModeAdministratorPassword (ConvertTo-SecureString 'P@ssw0rd123!' -AsPlainText -Force)",
    "-InstallDns -Force\""
  ]) })
}

# WS01 and WS02 join extensions.
# depends_on = [setup_dc] means these CANNOT start until DC01 promotion succeeds.
locals {
  join_cmd = join(" ", [
    "powershell -ExecutionPolicy Unrestricted -Command",
    "\"$a=Get-NetAdapter|?{$_.Status -eq 'Up'}|Select -First 1;",
    "Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ServerAddresses '10.0.1.4';",
    "do{Start-Sleep 15}until([bool](Resolve-DnsName '${var.domain_name}' -ErrorAction SilentlyContinue));",
    "Add-Computer -DomainName '${var.domain_name}'",
    "-Credential (New-Object PSCredential('${var.domain_netbios}\\${var.admin_username}',",
    "(ConvertTo-SecureString '${var.admin_password}' -AsPlainText -Force)))",
    "-Restart -Force\""
  ])
}
resource "azurerm_virtual_machine_extension" "join_ws01" {
  name                 = "JoinDomain"
  virtual_machine_id   = azurerm_windows_virtual_machine.ws01.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"
  settings             = jsonencode({ commandToExecute = local.join_cmd })
  depends_on           = [azurerm_virtual_machine_extension.setup_dc]
}
resource "azurerm_virtual_machine_extension" "join_ws02" {
  name                 = "JoinDomain"
  virtual_machine_id   = azurerm_windows_virtual_machine.ws02.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"
  settings             = jsonencode({ commandToExecute = local.join_cmd })
  depends_on           = [azurerm_virtual_machine_extension.setup_dc]
}

output "dc01_id"        { value = azurerm_windows_virtual_machine.dc01.id }
output "ws01_id"        { value = azurerm_windows_virtual_machine.ws01.id }
output "ws02_id"        { value = azurerm_windows_virtual_machine.ws02.id }
output "dc01_public_ip" { value = azurerm_public_ip.dc01.ip_address }
output "ws01_public_ip" { value = azurerm_public_ip.ws01.ip_address }
output "ws02_public_ip" { value = azurerm_public_ip.ws02.ip_address }

