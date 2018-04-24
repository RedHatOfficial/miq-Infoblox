# Creates a host record in Infoblox for the given VM and network configuration
#
# @param network_name String Name of the network to acquire an IP for
#
# @sets acquired_ip_address String IP address acquired from DDI provider
#
@DEBUG = false

require 'rest-client'
require 'json'
require 'base64'

ADDRESS_SPACE_TAG_CATEGORY = "network_address_space"
INFOBLOX_CONFIG            = $evm.instantiate('Integration/Infoblox/Configuration/default')

# Log an error and exit.
#
# @param msg Message to error with
def error(msg)
  $evm.log(:error, msg)
  $evm.root['ae_result'] = 'error'
  $evm.root['ae_reason'] = msg.to_s
  exit MIQ_STOP
end

def dump_object(object_string, object)
  $evm.log("info", "Listing #{object_string} Attributes:") 
  object.attributes.sort.each { |k, v| $evm.log("info", "\t#{k}: #{v}") }
  $evm.log("info", "===========================================") 
end

def dump_current
  $evm.log("info", "Listing Current Object Attributes:") 
  $evm.current.attributes.sort.each { |k, v| $evm.log("info", "\t#{k}: #{v}") }
  $evm.log("info", "===========================================") 
end

def dump_root
  $evm.log("info", "Listing Root Object Attributes:") 
  $evm.root.attributes.sort.each { |k, v| $evm.log("info", "\t#{k}: #{v}") }
  $evm.log("info", "===========================================") 
end

# Notify and log a warning message.
#
# @param msg Message to warn with
def warn(msg)
  $evm.create_notification(:level => 'warning', :message => msg)
  $evm.log(:warn, msg)
end

# Function for getting the current VM and associated options based on the vmdb_object_type.
#
# Supported vmdb_object_types
#   * miq_provision
#   * vm
#   * automation_task
#
# @return vm,options
def get_vm_and_options()
  $evm.log(:info, "$evm.root['vmdb_object_type'] => '#{$evm.root['vmdb_object_type']}'.")
  case $evm.root['vmdb_object_type']
    when 'miq_provision'
      # get root object
      $evm.log(:info, "Get VM and dialog attributes from $evm.root['miq_provision']") if @DEBUG
      miq_provision = $evm.root['miq_provision']
      dump_object('miq_provision', miq_provision) if @DEBUG
      
      # get VM
      vm = miq_provision.vm
    
      # get options
      options = miq_provision.options
      #merge the ws_values, dialog, top level options into one list to make it easier to search
      options = options.merge(options[:ws_values]) if options[:ws_values]
      options = options.merge(options[:dialog])    if options[:dialog]
    when 'vm'
      # get root object & VM
      $evm.log(:info, "Get VM from parameter and dialog attributes form $evm.root") if @DEBUG
      vm = get_param(:vm)
      dump_object('vm', vm) if @DEBUG
    
      # get options
      options = $evm.root.attributes
      #merge the ws_values, dialog, top level options into one list to make it easier to search
      options = options.merge(options[:ws_values]) if options[:ws_values]
      options = options.merge(options[:dialog])    if options[:dialog]
    when 'automation_task'
      # get root object
      $evm.log(:info, "Get VM from parameter and dialog attributes form $evm.root") if @DEBUG
      automation_task = $evm.root['automation_task']
      dump_object('automation_task', automation_task) if @DEBUG
      
      # get VM
      vm  = get_param(:vm)
      
      # get options
      options = get_param(:options)
      options = JSON.load(options)     if options && options.class == String
      options = options.symbolize_keys if options
      #merge the ws_values, dialog, top level options into one list to make it easier to search
      options = options.merge(options[:ws_values]) if options[:ws_values]
      options = options.merge(options[:dialog])    if options[:dialog]
    else
      error("Can not handle vmdb_object_type: #{$evm.root['vmdb_object_type']}")
  end
  
  # standardize the option keys
  options = options.symbolize_keys()
  
  $evm.log(:info, "vm      => #{vm}")      if @DEBUG
  $evm.log(:info, "options => #{options}") if @DEBUG
  return vm,options
end

# There are many ways to attempt to pass parameters in Automate.
# This function checks all of them in priorty order as well as checking for symbol or string.
#
# Order:
#   1. Inputs
#   2. Current
#   3. Object
#   4. Root
#   5. State
#
# @return Value for the given parameter or nil if none is found
def get_param(param)  
  # check if inputs has been set for given param
  param_value ||= $evm.inputs[param.to_sym]
  param_value ||= $evm.inputs[param.to_s]
  
  # else check if current has been set for given param
  param_value ||= $evm.current[param.to_sym]
  param_value ||= $evm.current[param.to_s]
 
  # else cehck if current has been set for given param
  param_value ||= $evm.object[param.to_sym]
  param_value ||= $evm.object[param.to_s]
  
  # else check if param on root has been set for given param
  param_value ||= $evm.root[param.to_sym]
  param_value ||= $evm.root[param.to_s]
  
  # check if state has been set for given param
  param_value ||= $evm.get_state_var(param.to_sym)
  param_value ||= $evm.get_state_var(param.to_s)

  $evm.log(:info, "{ '#{param}' => '#{param_value}' }") if @DEBUG
  return param_value
end

# Get the network configuration for a given network
#
# @param network_name Name of the network to get the configuraiton for
# @return Hash Configuration information about the given network
#                network_purpose
#                network_address_space
#                network_gateway
#                network_nameservers
#                network_ddi_provider
@network_configurations         = {}
@missing_network_configurations = {}
NETWORK_CONFIGURATION_URI       = 'Infrastructure/Network/Configuration'.freeze
def get_network_configuration(network_name)
  if @network_configurations[network_name].blank? && @missing_network_configurations[network_name].blank?
    begin
      @network_configurations[network_name] = $evm.instantiate("#{NETWORK_CONFIGURATION_URI}/#{network_name}")
    rescue => e
      @missing_network_configurations[network_name] = "WARN: No network configuration exists"
      $evm.log(:warn, "No network configuration for Network <#{network_name}> exists")
    end
  end
  return @network_configurations[network_name]
end

def infoblox_request(action, path, payload=nil)
  #https://infoblox_server/wapidoc/ for reference
  #https://community.infoblox.com/t5/API-Integration/The-definitive-list-of-REST-examples/td-p/1214
  infoblox_server      = INFOBLOX_CONFIG['server']
  infoblox_api_version = INFOBLOX_CONFIG['api_version']
  infoblox_username    = INFOBLOX_CONFIG['username']
  infoblox_password    = INFOBLOX_CONFIG.decrypt('password')

  url_base = "https://#{infoblox_server}/wapi/#{infoblox_api_version}/"
  url = url_base+path

  params = {
    :method     => action,
    :url        => url_base+path,
    :verify_ssl => false,
    :headers    => {
      :content_type  => :json,
      :accept        => :json,
      :authorization => "Basic #{Base64.encode64("#{infoblox_username}:#{infoblox_password}")}"
    }
  }
  params[:payload] = payload if payload
  
  $evm.log(:info, "Infoblox request params: #{params}")   if @DEBUG
  $evm.log(:info, "Infoblox request payload: #{payload}") if @DEBUG

  begin
    response = RestClient::Request.new(params).execute
    return JSON.parse(response)
  rescue => e
    error("Error making Infoblox request: #{e.response}")
  end
end

begin
  dump_root()    if @DEBUG
  dump_current() if @DEBUG
  
  # get the VM and options
  vm,options = get_vm_and_options()
  
  if INFOBLOX_CONFIG.nil? or INFOBLOX_CONFIG['server'] == 'infoblox.example.com'
    error("Infoblox configuration must be defined")
  else
    # get the network configuration
    network_name = options[:network_name] || options[:dialog_network_name] || get_param(:network_name) || get_param(:dialog_network_name)
    $evm.log(:info, "network_name => #{network_name}") if @DEBUG
    network_configuration = get_network_configuration(network_name)
    $evm.log(:info, "network_configuration => #{network_configuration}") if @DEBUG
    
    # get the network_address_space
    network_address_space = network_configuration['network_address_space']
    $evm.log(:info, "network_address_space => #{network_address_space}") if @DEBUG

    # determine vm hostname, first try to get hostname entry, else use vm name
    vm_hostname   = vm.hostnames.first if !vm.hostnames.empty?
    vm_hostname ||= vm.name
    
    # create the new DNS record
    payload = {
      "name"              => vm_hostname,
      "ipv4addrs"         => [{"ipv4addr"=>"func:nextavailableip:#{network_address_space}"}],
      "configure_for_dns" => true
    }
    creation_result = infoblox_request(:post, "record:host", payload.to_json)
    new_record      = infoblox_request(:get, creation_result)
    $evm.log(:info, "Created new DNS record: "+new_record.to_s) if @DEBUG

    # get the new IP from the new DNS record
    ip = new_record["ipv4addrs"].first["ipv4addr"] || nil
    error("Failed to get IP from Infoblox") if ip.nil?
    $evm.log(:info, "New IP address from Infoblox: "+ip) if @DEBUG
    
    # save the acquired IP for use later
    $evm.object['acquired_ip_address'] = ip
    $evm.set_state_var(:acquired_ip_address, ip)
    $evm.log(:info, "$evm.object['acquired_ip_address'] => #{$evm.object['acquired_ip_address']}") if @DEBUG
  end
rescue => err
  $evm.log(:error, "[#{err}]\n#{err.backtrace.join("\n")}")
  error("Error creating Infoblox host entry")
end
