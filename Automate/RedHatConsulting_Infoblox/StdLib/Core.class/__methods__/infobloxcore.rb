#
# Description: Collection of Core Infoblox Methods
# include line: include RedHatConsulting_Infoblox::StdLib::InfobloxCore

require 'rest-client'
require 'json'
require 'base64'

module RedHatConsulting_Infoblox
  module StdLib
    module InfobloxCore
      include RedHatConsulting_Utilities::StdLib::Core

      INFOBLOX_CONFIG  = $evm.instantiate('Integration/Infoblox/Configuration/default')

      def initialize(handle = $evm)
        @handle = handle
        @DEBUG = false
      end

      def infoblox_request(action, path, payload=nil)
        #https://infoblox_server/wapidoc/ for reference
        #https://community.infoblox.com/t5/API-Integration/The-definitive-list-of-REST-examples/td-p/1214
        infoblox_server      = INFOBLOX_CONFIG['server']
        infoblox_api_version = INFOBLOX_CONFIG['api_version']
        infoblox_username    = INFOBLOX_CONFIG['username']
        infoblox_verify_ssl  = INFOBLOX_CONFIG['verify_ssl'] || false
        infoblox_password    = INFOBLOX_CONFIG.decrypt('password')

        url_base = "https://#{infoblox_server}/wapi/#{infoblox_api_version}"
        url = "#{url_base}/#{path}"

        params = {
          :method     => action,
          :url        => url,
          :verify_ssl => infoblox_verify_ssl,
          :headers    => {
            :content_type  => :json,
            :accept        => :json,
            :authorization => "Basic #{Base64.encode64("#{infoblox_username}:#{infoblox_password}")}"
            }
          }
        params[:payload] = payload unless payload.blank?

        @handle.log(:info, "Infoblox request params: #{params}") if @DEBUG
        @handle.log(:info, "Infoblox request payload: #{payload}") unless payload.blank?

        response = RestClient::Request.new(params).execute
        return JSON.parse(response)
      end

      def get_host_records( vm_name )
        # %2B is a URL encoded '+'
        path = "record:host?name=#{vm_name}&_return_fields%2B=aliases"
        host_records = infoblox_request(:get, path)
        @handle.log(:info, "Infoblox response querying for #{vm_name}: #{host_records.inspect}")
        return host_records
      end

    end
  end
end
