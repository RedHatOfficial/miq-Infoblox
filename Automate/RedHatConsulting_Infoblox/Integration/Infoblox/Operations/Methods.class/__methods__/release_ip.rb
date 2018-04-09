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

# Log an error and exit.
#
# @param msg Message to error with
def error(msg)
  $evm.log(:error, msg)
  $evm.root['ae_result'] = 'error'
  $evm.root['ae_reason'] = msg.to_s
  exit MIQ_STOP
end

INFOBLOX_CONFIG = $evm.instantiate('Integration/Infoblox/Configuration/default')

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
  # Get provisioning object
  prov = $evm.root['miq_provision']
  error('Provisioning request not found') if prov.nil?
  # get the VM
  vm = prov.vm
  error('VM on provisioning request not found') if vm.nil?
  name = vm.name

  $evm.log(:info, "vm = #{vm}") if @DEBUG

  if INFOBLOX_CONFIG.nil? or INFOBLOX_CONFIG['server'] == 'infoblox.example.com'
    error("Infoblox configuration must be defined")
  else
    host = infoblox_request(:get, "record:host?name=#{name}").first["_ref"]
    infoblox_request(:delete, host)
  end
rescue
  error("Error releasing IP address")
end
