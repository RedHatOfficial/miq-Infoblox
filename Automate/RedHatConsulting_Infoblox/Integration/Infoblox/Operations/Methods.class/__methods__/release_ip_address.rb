# Deletes a host record in Infoblox for the given VM associated with a provisioning request, which releases the associated IP address
#
# @sets released_ip_address String IP address released from DDI provider
#
@DEBUG = false

require 'rest-client'
require 'json'
require 'base64'

INFOBLOX_CONFIG = $evm.instantiate('Integration/Infoblox/Configuration/default')

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
      # get root objet & VM
      $evm.log(:info, "Get VM from paramater and dialog attributes form $evm.root") if @DEBUG
      vm = get_param(:vm)
      dump_object('vm', vm) if @DEBUG
    
      # get options
      options = $evm.root.attributes
      #merge the ws_values, dialog, top level options into one list to make it easier to search
      options = options.merge(options[:ws_values]) if options[:ws_values]
      options = options.merge(options[:dialog])    if options[:dialog]
    when 'automation_task'
      # get root objet
      $evm.log(:info, "Get VM from paramater and dialog attributes form $evm.root") if @DEBUG
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
  
  # standerdize the option keys
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

def infoblox_request(action, path, payload=nil)
  #https://infoblox_server/wapidoc/ for reference
  #https://community.infoblox.com/t5/API-Integration/The-definitive-list-of-REST-examples/td-p/1214
  infoblox_server   = INFOBLOX_CONFIG['server']
  infoblox_api_version = INFOBLOX_CONFIG['api_version']
  infoblox_username = INFOBLOX_CONFIG['username']
  infoblox_password = INFOBLOX_CONFIG.decrypt('password')

  url_base = "https://#{infoblox_server}/wapi/#{infoblox_api_version}/"
  url = url_base+path

  params = {
    :method=>action, :url=>url_base+path, :verify_ssl=>false,
    :headers=>{ :content_type=>:json, :accept=>:json,
                :authorization=>"Basic #{Base64.encode64("#{infoblox_username}:#{infoblox_password}")}"}
    }
  params[:payload] = payload if payload
  response = RestClient::Request.new(params).execute
  return JSON.parse(response)
end

begin
  dump_root()    if @DEBUG
  dump_current() if @DEBUG
  
  # get the VM and options
  vm,options = get_vm_and_options()

  if INFOBLOX_CONFIG.nil? or INFOBLOX_CONFIG['server'] == 'infoblox.example.com'
    error("Infoblox configuration must be defined")
  else
    # determine vm hostname, first try to get hostname entry, else use vm name
    vm_hostname   = vm.hostnames.first if !vm.hostnames.empty?
    vm_hostname ||= vm.name
    
    # get the infoblox host record to delete
    $evm.log(:info, "Delete Infoblox record for hostname <#{vm_hostname}>")
    infoblox_host_records = infoblox_request(:get, "record:host?name=#{vm_hostname}")
    
    # if Infoblox host records found to delete then delete them
    # else warn that no host records found to delete and move on.
    if !infoblox_host_records.empty?
      infoblox_host_records.each do |infoblox_host_record|
        infoblox_host_record_ref = infoblox_host_record['_ref']
        $evm.log(:info, "Delete Infoblox host record <#{infoblox_host_record_ref}> for hostname <#{vm_hostname}>") if @DEBUG
        
        # delete the infoblox host record
        begin
          delete_result = infoblox_request(:delete, infoblox_host_record_ref)
          $evm.log(:info, "Deleted Infoblox record <#{infoblox_host_record_ref}> for hostname <#{vm_hostname}>")
          
          # get IP that was released
          released_ip_address =  delete_result["ipv4addrs"].first["ipv4addr"] || nil
          
          # save the aquired IP for use later
          $evm.object['released_ip_address'] = ip
          $evm.set_state_var(:released_ip_address, ip)
          $evm.log(:info, "$evm.object['released_ip_address'] => #{$evm.object['released_ip_address']}") if @DEBUG
          
        rescue => delete_err
          warn("Error deleting Infoblox host record for hostname <#{vm_hostname}>. Ignoring & Skipping. #{delete_err}")
        end
      end
    else
      warn("No Infoblox host record to delete found for hostname <#{vm_hostname}>. Ignoring & Skipping.")
    end
  end
rescue => err
  $evm.log(:error, "[#{err}]\n#{err.backtrace.join("\n")}")
  error("Error deleting Infoblox DNS entry: #{err}")
end
