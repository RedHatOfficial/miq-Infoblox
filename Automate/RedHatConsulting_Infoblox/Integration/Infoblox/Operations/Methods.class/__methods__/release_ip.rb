# Deletes a host record in Infoblox for the given VM associated with a provisioning request, which releases the associated IP address
#
# EXPECTED
#   EVM ROOT
#     miq_provision - VM Provisioning request to release IP address for
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

# Notify and log a warning message.
#
# @param msg Message to warn with
def warn(msg)
  $evm.create_notification(:level => 'warning', :message => msg)
  $evm.log(:warn, msg)
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
  $evm.log(:info, "$evm.root['vmdb_object_type'] => '#{$evm.root['vmdb_object_type']}'") if @DEBUG
  case $evm.root['vmdb_object_type']
    when 'miq_provision'
      $evm.log(:info, "Get VM and dialog attributes from $evm.root['miq_provision']") if @DEBUG
      miq_provision = $evm.root['miq_provision']
      vm            = miq_provision.vm
      options       = miq_provision.options
      
      #merge the ws_values, dialog, top level options into one list to make it easier to search
      options = options.merge(options[:ws_values]) if options[:ws_values]
      options = options.merge(options[:dialog])    if options[:dialog]
    when 'vm'
      $evm.log(:info, "Get VM from paramater and dialog attributes form $evm.root") if @DEBUG
      vm      = get_param(:vm)
      options = $evm.root.attributes
      
      #merge the ws_values, dialog, top level options into one list to make it easier to search
      options = options.merge(options[:ws_values]) if options[:ws_values]
      options = options.merge(options[:dialog])    if options[:dialog]
    when 'automation_task'
      $evm.log(:info, "Get VM from paramater and dialog attributes form $evm.root") if @DEBUG
      automation_task = $evm.root['automation_task']
      dump_object("automation_task", automation_task) if @DEBUG
      
      vm  = get_param(:vm)
  end
  error('VM parameter not found') if vm.nil?
  $evm.log(:info, "vm => #{vm}") if @DEBUG

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
          infoblox_request(:delete, infoblox_host_record_ref)
          $evm.log(:info, "Deleted Infoblox record <#{infoblox_host_record_ref}> for hostname <#{vm_hostname}>")
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
