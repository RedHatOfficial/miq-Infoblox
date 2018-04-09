# Creates a host record in Infoblox for the given VM associated with a provisioning request
#
# EXPECTED
#   EVM ROOT
#     miq_provision - VM Provisioning request to create the Infoblox host record for.
@DEBUG = false

require 'rest-client'
require 'json'
require 'base64'

ADDRESS_SPACE_TAG = "network_address_space"

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

#IMPLIMENTORS: Modify as necessary
#Use this method to pick the subnet on which to create Infoblox records
#Should return a string subnet in the format IP/netmask e.g. "127.31.0.0/24"
def select_subnet()
  destination_name = $evm.root['dialog_subnet']
  destination_lan = $evm.vmdb(:lan).find_by_name(destination_name)
  
  address_range = $evm.vmdb(:classification).find_by_name(ADDRESS_SPACE_TAG+"/"+lan_name).description
  
  return address_range
end

begin
  prov = $evm.root['miq_provision']
  error('Provisioning request not found') if prov.nil?
  vm = prov.vm
  error('VM not associated with provisioning request') if vm.nil?

  $evm.log(:info, "vm = #{vm}") if @DEBUG

  if INFOBLOX_CONFIG.nil? or INFOBLOX_CONFIG['server'] == 'infoblox.example.com'
    error("Infoblox configuration must be defined")
  else
    subnet = select_subnet()

    name = vm.name
    payload = {
      "name"=>name,
      "ipv4addrs"=>[{"ipv4addr"=>"func:nextavailableip:#{subnet}"}],
      "configure_for_dns"=>true
    }

    creation_result = infoblox_request(:post, "record:host", payload.to_json)
    new_record = infoblox_request(:get, creation_result)
    $evm.log(:info, "Created new DHCP record: "+new_record.to_s) if @DEBUG

    ip = new_record["ipv4addrs"].first["ipv4addr"] || nil
    error("Failed to get IP from Infoblox") if ip.nil?
    $evm.log(:info, "New IP address from Infoblox: "+ip) if @DEBUG
    $evm.set_state_var(:infoblox_ip, ip)
  end
rescue
  error("Error assigning IP address")
end
