# Creates a host record in Infoblox for the given VM and network configuration
#
# @param network_name String Name of the network to acquire an IP for
#
# @sets acquired_ip_address String IP address acquired from DDI provider
#
# Integration / Infoblox / Operations / Methods / acquire_ip_address

require 'rest-client'
require 'json'
require 'base64'

module RedHatConsulting_Infoblox
  module Integration
    module Infoblox
      module Operations
        module Methods
          class AcquireIPAddress

            include RedHatConsulting_Utilities::StdLib::Core
            include RedHatConsulting_Infoblox::StdLib::InfobloxCore
            ADDRESS_SPACE_TAG_CATEGORY = "network_address_space"
            INFOBLOX_CONFIG            = $evm.instantiate('Integration/Infoblox/Configuration/default')
            NETWORK_CONFIGURATION_URI  = 'Infrastructure/Network/Configuration'.freeze

            def initialize(handle = $evm)
              @handle = handle
              @DEBUG = false
              @network_configurations         = {}
              @missing_network_configurations = {}
            end

            def main
              begin
                dump_root()    if @DEBUG

                # get the VM and options
                vm,options = get_vm_and_options()

                if INFOBLOX_CONFIG.nil? or INFOBLOX_CONFIG['server'] == 'infoblox.example.com'
                  error("Infoblox configuration must be defined")
                else
                  # get the network configuration
                  network_name = get_param(:network_name) || get_param(:dialog_network_name) || options[:network_name] || options[:dialog_network_name]
                  log(:info, "network_name => #{network_name}") if @DEBUG
                  network_configuration = get_network_configuration(network_name)
                  log(:info, "network_configuration => #{network_configuration}") if @DEBUG

                  # get the network_address_space
                  network_address_space = network_configuration['network_address_space']
                  log(:info, "network_address_space => #{network_address_space}") if @DEBUG

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
                  log(:info, "Created new DNS record: #{new_record.to_s}" ) if @DEBUG

                  # get the new IP from the new DNS record
                  ip = new_record["ipv4addrs"].first["ipv4addr"] || nil
                  error("Failed to get IP from Infoblox") if ip.nil?
                  log(:info, "New IP address from Infoblox: #{ip}") if @DEBUG

                  # save the acquired IP for use later
                  @handle.object['acquired_ip_address'] = ip
                  @handle.set_state_var(:acquired_ip_address, ip)
                  log(:info, "$evm.object['acquired_ip_address'] => #{@handle.object['acquired_ip_address']}") if @DEBUG
                end
              rescue => err
                log(:error, "[#{err}]\n#{err.backtrace.join("\n")}")
                error("Error creating Infoblox host entry")
              end
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
            def get_network_configuration(network_name)
              if @network_configurations[network_name].blank? && @missing_network_configurations[network_name].blank?
                begin
                  escaped_network_name                  = network_name.gsub(/[^a-zA-Z0-9_\.\-]/, '_')
                  @network_configurations[network_name] = @handle.instantiate("#{NETWORK_CONFIGURATION_URI}/#{escaped_network_name}")

                  if escaped_network_name =~ /^dvs_/ && @network_configurations[network_name]['network_address_space'].blank?
                    escaped_network_name                  = escaped_network_name[/^dvs_(.*)/, 1]
                    @network_configurations[network_name] = @handle.instantiate("#{NETWORK_CONFIGURATION_URI}/#{escaped_network_name}")
                  end
                rescue
                  @missing_network_configurations[network_name] = "WARN: No network configuration exists"
                  log(:warn, "No network configuration for Network <#{network_name}> (escaped <#{escaped_network_name}>) exists")
                end
              end
              return @network_configurations[network_name]
            end

          end
        end
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  RedHatConsulting_Infoblox::Integration::Infoblox::Operations::Methods::AcquireIPAddress.new.main
end
