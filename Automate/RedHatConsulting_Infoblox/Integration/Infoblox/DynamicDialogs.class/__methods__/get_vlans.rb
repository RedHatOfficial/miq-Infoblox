# Populates a dialog element with information about valid destination vlans for each
# Selected destination location and the selected OS version.
# Relies on get_templates_based_on_selected_os_and_location to do the heavy lifting of finding vlans, then displays those
require 'yaml'

ADDRESS_SPACE_TAG               = 'network_address_space'
TEMPLATES_DIALOG_OPTION         = 'dialog_templates'

@DEBUG = false

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

begin
  dump_root()    if @DEBUG
  dump_current() if @DEBUG
  
  # If there isn't a vmdb_object_type yet just exit. The method will be recalled with an vmdb_object_type
  exit MIQ_OK unless $evm.root['vmdb_object_type']
  
  selectable_lans = {}
  # Don't do anything unless template data has already been figured out
  unless $evm.root[TEMPLATES_DIALOG_OPTION].include?("INVALID SELECTION")
    template_data = YAML.load($evm.root[TEMPLATES_DIALOG_OPTION])
    destination_lans = template_data[0][:destination_lans]
    $evm.log(:info, "Tagged destination lans: "+destination_lans.to_s) if @DEBUG
  
    destination_lans.each do |lan_name|
      lan = $evm.vmdb(:lan).find_by_name(lan_name)
      unless lan.tags("network_address_space").blank?
        selectable_lans[lan_name] = lan_name + ": "+$evm.vmdb(:classification).find_by_name(ADDRESS_SPACE_TAG+"/"+lan_name).description
      end
    end
  end
  
  list_values = {
    'sort_by'    => :value,
    'data_type'  => :string,
    'required'   => true,
    'values'     => selectable_lans
  }
  list_values.each { |key, value| $evm.object[key] = value }

 rescue => err
  $evm.log(:error, "[#{err}]\n#{err.backtrace.join("\n")}")
  exit MIQ_STOP
end
