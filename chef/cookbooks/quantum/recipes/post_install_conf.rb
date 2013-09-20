# Copyright 2011 Dell, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
require 'ipaddr'

def mask_to_bits(mask)
  IPAddr.new(mask).to_i.to_s(2).count("1")
end

fixed_net = node[:network][:networks]["nova_fixed"]
fixed_range = "#{fixed_net["subnet"]}/#{mask_to_bits(fixed_net["netmask"])}"
fixed_router_pool_start = fixed_net[:ranges][:router][:start]
fixed_router_pool_end = fixed_net[:ranges][:router][:end]
fixed_pool_start = fixed_net[:ranges][:dhcp][:start]
fixed_pool_end = fixed_net[:ranges][:dhcp][:end]
fixed_first_ip = IPAddr.new("#{fixed_range}").to_range().to_a[2]
fixed_last_ip = IPAddr.new("#{fixed_range}").to_range().to_a[-2]

fixed_pool_start = fixed_first_ip if fixed_first_ip > fixed_pool_start
fixed_pool_end = fixed_last_ip if fixed_last_ip < fixed_pool_end 


#this code seems to be broken in case complicated network when floating network outside of public network
public_net = node[:network][:networks]["public"]
public_range = "#{public_net["subnet"]}/#{mask_to_bits(public_net["netmask"])}"
public_router = "#{public_net["router"]}"
public_vlan = public_net["vlan"]
floating_net = node[:network][:networks]["nova_floating"]
floating_range = "#{floating_net["subnet"]}/#{mask_to_bits(floating_net["netmask"])}"
floating_pool_start = floating_net[:ranges][:host][:start]
floating_pool_end = floating_net[:ranges][:host][:end]

floating_first_ip = IPAddr.new("#{public_range}").to_range().to_a[2]
floating_last_ip = IPAddr.new("#{public_range}").to_range().to_a[-2]
floating_pool_start = floating_first_ip if floating_first_ip > floating_pool_start

floating_pool_end = floating_last_ip if floating_last_ip < floating_pool_end

env_filter = " AND keystone_config_environment:keystone-config-#{node[:quantum][:keystone_instance]}"
keystones = search(:node, "recipes:keystone\\:\\:server#{env_filter}") || []
if keystones.length > 0
  keystone = keystones[0]
  keystone = node if keystone.name == node.name
else
  keystone = node
end

keystone_address = Chef::Recipe::Barclamp::Inventory.get_network_by_type(keystone, "admin").address if keystone_address.nil?
keystone_service_port = keystone["keystone"]["api"]["service_port"]
admin_username = keystone["keystone"]["admin"]["username"] rescue nil
admin_password = keystone["keystone"]["admin"]["password"] rescue nil
admin_tenant = keystone["keystone"]["admin"]["tenant"] rescue "admin"
Chef::Log.info("Keystone server found at #{keystone_address}")


ENV['OS_USERNAME'] = admin_username
ENV['OS_PASSWORD'] = admin_password
ENV['OS_TENANT_NAME'] = admin_tenant
ENV['OS_AUTH_URL'] = "http://#{keystone_address}:#{keystone_service_port}/v2.0/"

floating_network_type = ""
case node[:quantum][:networking_plugin]
when "openvswitch"
  floating_network_type = ""
  if node[:quantum][:networking_mode] == 'vlan'
    fixed_network_type = "--provider:network_type vlan --provider:segmentation_id #{fixed_net["vlan"]} --provider:physical_network physnet1"
  elsif node[:quantum][:networking_mode] == 'gre'
    fixed_network_type = "--provider:network_type gre --provider:segmentation_id 1"
    floating_network_type = "--provider:network_type gre --provider:segmentation_id 2"
  else
    fixed_network_type = "--provider:network_type flat --provider:physical_network physnet1"
  end
when "linuxbridge"
  fixed_network_type = "--provider:network_type vlan --provider:segmentation_id #{fixed_net["vlan"]} --provider:physical_network physnet1"
  floating_network_type = "--provider:network_type vlan --provider:segmentation_id #{public_net["vlan"]} --provider:physical_network physnet1"
end

execute "create_fixed_network" do
  command "quantum net-create fixed --shared #{fixed_network_type}"
  not_if "out=$(quantum net-list); [ $? != 0 ] || echo ${out} | grep -q ' fixed '"
end

execute "create_floating_network" do
  command "quantum net-create floating --router:external=True #{floating_network_type}"
  not_if "out=$(quantum net-list); [ $? != 0 ] || echo ${out} | grep -q ' floating '"
end

execute "create_fixed_subnet" do
  command "quantum subnet-create --name fixed --allocation-pool start=#{fixed_pool_start},end=#{fixed_pool_end} --gateway #{fixed_router_pool_end} fixed #{fixed_range}"
  not_if "out=$(quantum subnet-list); [ $? != 0 ] || echo ${out} | grep -q ' fixed '"
end
execute "create_floating_subnet" do
  command "quantum subnet-create --name floating --allocation-pool start=#{floating_pool_start},end=#{floating_pool_end} --gateway #{public_router} floating #{public_range} --enable_dhcp False"
  not_if "out=$(quantum subnet-list); [ $? != 0 ] || echo ${out} | grep -q ' floating '"
end

execute "create_router" do
  command <<EOC
quantum router-create router-floating && \
    quantum router-gateway-set router-floating floating
EOC
  not_if "out=$(quantum router-list); [ $? != 0 ] || echo ${out} | grep -q router-floating"
end

bash "add fixed network to router" do
  code <<EOC
# Get the ID of the fixed net
. <(quantum subnet-show -f shell -c id fixed)
if ! grep "$id" <(quantum router-port-list -f csv router-floating); then
    quantum router-interface-add router-floating fixed
fi
EOC
end

if node[:quantum][:networking_plugin] == "linuxbridge"
  bound_if = (node[:crowbar_wall][:network][:nets][:public].last rescue nil)
  quantum_bridge "floating bridge" do
    network_name "floating"
    slaves [bound_if]
    type "linuxbridge"

    action :create
  end
end
