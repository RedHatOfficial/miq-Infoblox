# Deletes a host record in Infoblox for the given VM associated with a provisioning request, which releases the associated IP address
#
# @sets released_ip_address String IP address released from DDI provider
#
# Integration / Infoblox / Operations / Methods / release_ip_address

require 'rest-client'
require 'json'
require 'base64'

module RedHatConsulting_Infoblox
  module Integration
    module Infoblox
      module Operations
        module Methods
          class ReleaseIPAddress

            include RedHatConsulting_Utilities::StdLib::Core
            include RedHatConsulting_Infoblox::StdLib::InfobloxCore
            INFOBLOX_CONFIG = $evm.instantiate('Integration/Infoblox/Configuration/default')

            def initialize(handle = $evm)
              @handle = handle
              @DEBUG  = false
            end

            def main
              begin
                dump_root()    if @DEBUG

                # get the VM and options
                vm,options = get_vm_and_options()

                if INFOBLOX_CONFIG.nil? or INFOBLOX_CONFIG['server'] == 'infoblox.example.com'
                  error("Infoblox configuration must be defined")
                else
                  # determine vm hostname, first try to get hostname entry, else use vm name
                  vm_hostname   = vm.hostnames.first if !vm.hostnames.empty?
                  vm_hostname ||= vm.name

                  # get the infoblox host record to delete
                  log(:info, "Delete Infoblox record for hostname <#{vm_hostname}>")
                  infoblox_host_records = get_host_records(vm_hostname)

                  # if Infoblox host records found to delete then delete them
                  # else warn that no host records found to delete and move on.
                  if infoblox_host_records.present?
                    infoblox_host_records.each do |infoblox_host_record|
                      log(:info, "infoblox_host_record => #{infoblox_host_record}") if @DEBUG

                      # get the ref of the record to delete
                      infoblox_host_record_ref = infoblox_host_record['_ref']
                      log(:info, "Delete Infoblox host record <#{infoblox_host_record_ref}> for hostname <#{vm_hostname}>") if @DEBUG

                      # delete the infoblox host record
                      begin
                        delete_result = infoblox_request(:delete, infoblox_host_record_ref)
                        log(:info, "Deleted Infoblox record <#{infoblox_host_record_ref}> for hostname <#{vm_hostname}>")
                        log(:info, "delete_result => #{delete_result}") if @DEBUG

                        # get IP that was released
                        released_ip_address =  infoblox_host_record["ipv4addrs"].first.blank? ? nil : infoblox_host_record["ipv4addrs"].first["ipv4addr"]

                        # save the released IP for use later
                        @handle.object['released_ip_address'] = released_ip_address
                        @handle.set_state_var(:released_ip_address, released_ip_address)
                        log(:info, "$evm.object['released_ip_address'] => #{$evm.object['released_ip_address']}") if @DEBUG
                      rescue => delete_err
                        log(:warn, "Error deleting Infoblox host record for hostname <#{vm_hostname}>. Ignoring & Skipping. #{delete_err.message}")
                      end
                    end
                  else
                    log(:warn, "No Infoblox host record to delete found for hostname <#{vm_hostname}>. Ignoring & Skipping.")
                  end
                end
              rescue => err
                log(:error, "[#{err}]\n#{err.backtrace.join("\n")}")
                error("Error deleting Infoblox DNS entry: #{err.message}")
              end
            end

          end
        end
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  RedHatConsulting_Infoblox::Integration::Infoblox::Operations::Methods::ReleaseIPAddress.new.main
end
