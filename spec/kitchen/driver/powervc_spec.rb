# Encoding: UTF-8

require_relative '../../spec_helper'
require_relative '../../../lib/kitchen/driver/powervc'

require 'logger'
require 'stringio'
require 'rspec'
require 'kitchen'
require 'kitchen/driver/powervc'
require 'kitchen/provisioner/dummy'
require 'kitchen/transport/dummy'
require 'kitchen/verifier/dummy'
require 'ohai'
require 'excon'
require 'fog'

describe Kitchen::Driver::Powervc do
  let(:logged_output) { StringIO.new }
  let(:logger) { Logger.new(logged_output) }
  let(:config) { Hash.new }
  let(:state) { Hash.new }
  let(:dsa) { File.expand_path('~/.ssh/id_dsa') }
  let(:rsa) { File.expand_path('~/.ssh/id_rsa') }
  let(:instance_name) { 'potatoes' }
  let(:transport)     { Kitchen::Transport::Dummy.new }
  let(:platform)      { Kitchen::Platform.new(name: 'fake_platform') }
  let(:driver)        { Kitchen::Driver.powervc.new(config) }

  let(:instance) do
    double(
      name: instance_name,
      transport: transport,
      logger: logger,
      platform: platform,
      to_str: 'instance'
    )
  end

  let(:driver) { described_class.new(config) }

  before(:each) do
    allow_any_instance_of(described_class).to receive(:instance)
      .and_return(instance)
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?).with(dsa).and_return(true)
    allow(File).to receive(:exist?).with(rsa).and_return(true)
  end

  describe '#finalize_config' do
    before(:each) { allow(File).to receive(:exist?).and_return(false) }

    context 'both private and public key info provided' do
      let(:config) do
        { private_key_path: '/tmp/key', public_key_path: '/tmp/key.pub' }
      end

      it 'raises no error' do
        expect(driver.finalize_config!(instance)).to be
      end
    end

    context 'no key information provided provided' do
      let(:config) { {} }

      it 'raises an error' do
        expected = Kitchen::UserError
        expect { driver.finalize_config!(instance) }.to raise_error(expected)
      end
    end
  end

  describe '#initialize' do
    context 'default options' do
      it 'uses the normal SSH status check' do
        expect(driver[:no_ssh_tcp_check]).to eq(false)
      end

      it 'sets a default TCP check wait time' do
        expect(driver[:no_ssh_tcp_check_sleep]).to eq(120)
      end

      context 'both DSA and RSA SSH keys available for the user' do
        it 'prefers the local user\'s RSA private key' do
          expect(driver[:private_key_path]).to eq(rsa)
        end

        it 'prefers the local user\'s RSA public key' do
          expect(driver[:public_key_path]).to eq(rsa + '.pub')
        end
      end

      context 'only a DSA SSH key available for the user' do
        before(:each) do
          allow(File).to receive(:exist?).and_return(false)
          allow(File).to receive(:exist?).with(dsa).and_return(true)
        end

        it 'uses the local user\'s DSA private key' do
          expect(driver[:private_key_path]).to eq(dsa)
        end

        it 'uses the local user\'s DSA public key' do
          expect(driver[:public_key_path]).to eq(dsa + '.pub')
        end
      end

      context 'only a RSA SSH key available for the user' do
        before(:each) do
          allow(File).to receive(:exist?).and_return(false)
          allow(File).to receive(:exist?).with(rsa).and_return(true)
        end

        it 'uses the local user\'s RSA private key' do
          expect(driver[:private_key_path]).to eq(rsa)
        end

        it 'uses the local user\'s RSA public key' do
          expect(driver[:public_key_path]).to eq(rsa + '.pub')
        end
      end

      nils = [
        :server_name,
        :powervc_tenant,
        :powervc_region,
        :powervc_service_name,
        :floating_ip_pool,
        :floating_ip,
        :availability_zone,
        :security_groups,
        :network_ref
      ]
      nils.each do |i|
        it "defaults to no #{i}" do
          expect(driver[i]).to eq(nil)
        end
      end
    end

    context 'overridden options' do
      let(:config) do
        {
          image_ref: '22',
          flavor_ref: '33',
          public_key_path: '/tmp',
          username: 'admin',
          port: '2222',
          server_name: 'puppy',
          server_name_prefix: 'parsnip',
          powervc_tenant: 'that_one',
          powervc_region: 'atlantis',
          powervc_service_name: 'the_service',
          private_key_path: '/path/to/id_rsa',
          floating_ip_pool: 'swimmers',
          floating_ip: '11111',
          network_ref: '0xCAFFE',
          block_device_mapping: {
            make_volume: true,
            snapshot_id: '44',
            volume_id: '55',
            volume_size: '5',
            device_name: 'vda',
            delete_on_termination: true
          }
        }
      end

      it 'uses all the overridden options' do
        drv = driver
        config.each do |k, v|
          expect(drv[k]).to eq(v)
        end
      end

      it 'overrides server name prefix with explicit server name, if given' do
        expect(driver[:server_name]).to eq(config[:server_name])
      end
    end
  end

  describe '#create' do
    let(:server) do
      double(id: 'test123', wait_for: true, public_ip_addresses: %w(1.2.3.4))
    end
    let(:driver) do
      d = super()
      allow(d).to receive(:default_name).and_return('a_monkey!')
      allow(d).to receive(:create_server).and_return(server)
      allow(d).to receive(:wait_for_sshd).with('1.2.3.4', 'root', port: '22')
        .and_return(true)
      allow(d).to receive(:get_ip).and_return('1.2.3.4')
      allow(d).to receive(:add_ohai_hint).and_return(true)
      allow(d).to receive(:do_ssh_setup).and_return(true)
      allow(d).to receive(:sleep)
      allow(d).to receive(:wait_for_ssh_key_access).and_return('SSH key authetication successful') # rubocop:disable Metrics/LineLength
      allow(d).to receive(:disable_ssl_validation).and_return(false)
      d
    end

    context 'when a server is already created' do
      it 'does not create a new instance' do
        state[:server_id] = '1'
        expect(driver).not_to receive(:create_server)
        driver.create(state)
      end
    end

    context 'required options provided' do
      let(:config) do
        {
          powervc_username: 'hello',
          powervc_api_key: 'world',
          powervc_auth_url: 'http:',
          powervc_tenant: 'www',
          glance_cache_wait_timeout: 600,
          disable_ssl_validation: false
        }
      end
      let(:server) do
        double(id: 'test123', wait_for: true, public_ip_addresses: %w(1.2.3.4))
      end

      let(:driver) do
        d = described_class.new(config)
        allow(d).to receive(:config_server_name).and_return('a_monkey!')
        allow(d).to receive(:create_server).and_return(server)
        allow(server).to receive(:id).and_return('test123')

        # Inside the yield block we are calling ready?  So we fake it here
        allow(d).to receive(:ready?).and_return(true)
        allow(server).to receive(:wait_for)
          .with(an_instance_of(Fixnum)).and_yield

        allow(d).to receive(:get_ip).and_return('1.2.3.4')
        allow(d).to receive(:bourne_shell?).and_return(false)
        d
      end

      it 'returns nil, but modifies the state' do
        expect(driver.send(:create, state)).to eq(nil)
        expect(state[:server_id]).to eq('test123')
      end

      it 'throws an Action error when trying to create_server' do
        allow(driver).to receive(:create_server).and_raise(Fog::Errors::Error)
        expect { driver.send(:create, state) }.to raise_error(Kitchen::ActionFailed) # rubocop:disable Metrics/LineLength
      end
    end
  end

  describe '#destroy' do
    let(:server_id) { '12345' }
    let(:hostname) { 'example.com' }
    let(:state) { { server_id: server_id, hostname: hostname } }
    let(:server) { double(nil?: false, destroy: true) }
    let(:servers) { double(get: server) }
    let(:compute) { double(servers: servers) }

    let(:driver) do
      d = super()
      allow(d).to receive(:compute).and_return(compute)
      d
    end

    context 'a live server that needs to be destroyed' do
      it 'destroys the server' do
        expect(state).to receive(:delete).with(:server_id)
        expect(state).to receive(:delete).with(:hostname)
        driver.destroy(state)
      end

      it 'does not disable SSL cert validation' do
        expect(driver).to_not receive(:disable_ssl_validation)
        driver.destroy(state)
      end
    end

    context 'no server ID present' do
      let(:state) { Hash.new }

      it 'does nothing' do
        allow(driver).to receive(:compute)
        expect(driver).to_not receive(:compute)
        expect(state).to_not receive(:delete)
        driver.destroy(state)
      end
    end

    context 'a server that was already destroyed' do
      let(:servers) do
        s = double('servers')
        allow(s).to receive(:get).with('12345').and_return(nil)
        s
      end
      let(:compute) { double(servers: servers) }
      let(:driver) do
        d = super()
        allow(d).to receive(:compute).and_return(compute)
        d
      end

      it 'does not try to destroy the server again' do
        allow_message_expectations_on_nil
        driver.destroy(state)
      end
    end

    context 'SSL validation disabled' do
      let(:config) { { disable_ssl_validation: true } }

      it 'disables SSL cert validation' do
        expect(driver).to receive(:disable_ssl_validation)
        driver.destroy(state)
      end
    end
  end

  describe '#powervc_server' do
    let(:config) do
      {
        powervc_username: 'a',
        powervc_api_key: 'b',
        powervc_auth_url: 'http://',
        powervc_tenant: 'me',
        powervc_region: 'ORD',
        powervc_service_name: 'stack'
      }
    end

    it 'returns a hash of server settings' do
      expected = config.merge(provider: 'powervc')
      expect(driver.send(:powervc_server)).to eq(expected)
    end
  end

  describe '#required_server_settings' do
    it 'returns the required settings for an powervc server' do
      expected = [
        :powervc_username, :powervc_api_key, :powervc_auth_url
      ]
      expect(driver.send(:required_server_settings)).to eq(expected)
    end
  end

  describe '#optional_server_settings' do
    it 'returns the optional settings for an powervc server' do
      excluded = [
        :powervc_username, :powervc_api_key, :powervc_auth_url
      ]
      expect(driver.send(:optional_server_settings)).not_to include(*excluded)
    end
  end

  describe '#compute' do
    let(:config) do
      {
        powervc_username: 'monkey',
        powervc_api_key: 'potato',
        powervc_auth_url: 'http:',
        powervc_tenant: 'link',
        powervc_region: 'ord',
        powervc_service_name: 'the_service'
      }
    end

    context 'all requirements provided' do
      it 'creates a new compute connection' do
        allow(Fog::Compute).to receive(:new) { |arg| arg }
        res = config.merge(provider: 'powervc')
        expect(driver.send(:compute)).to eq(res)
      end

      it 'creates a new network connection' do
        allow(Fog::Network).to receive(:new) { |arg| arg }
        res = config.merge(provider: 'powervc')
        expect(driver.send(:network)).to eq(res)
      end
    end

    context 'only an API key provided' do
      let(:config) { { powervc_api_key: '1234' } }

      it 'raises an error' do
        expect { driver.send(:compute) }.to raise_error(ArgumentError)
      end
    end

    context 'only a username provided' do
      let(:config) { { powervc_username: 'monkey' } }

      it 'raises an error' do
        expect { driver.send(:compute) }.to raise_error(ArgumentError)
      end
    end
  end

  describe '#create_server' do
    let(:config) do
      {
        server_name: 'hello',
        image_ref: '111',
        flavor_ref: '1',
        availability_zone: nil,
        public_key_path: 'tarpals',
        block_device_mapping: {
          volume_size: '5',
          volume_id: '333',
          volume_device_name: 'vda',
          delete_on_termination: 'true'
        }
      }
    end
    let(:servers) do
      s = double('servers')
      allow(s).to receive(:create) { |arg| arg }
      s
    end
    let(:vlan1_net) { double(id: '1', name: 'vlan1') }
    let(:vlan2_net) { double(id: '2', name: 'vlan2') }
    let(:ubuntu_image) { double(id: '111', name: 'ubuntu') }
    let(:fedora_image) { double(id: '222', name: 'fedora') }
    let(:tiny_flavor) { double(id: '1', name: 'tiny') }
    let(:small_flavor) { double(id: '2', name: 'small') }
    let(:compute) do
      double(
        servers: servers,
        images: [ubuntu_image, fedora_image],
        flavors: [tiny_flavor, small_flavor]
      )
    end
    let(:network) do
      double(networks: double(all: [vlan1_net, vlan2_net]))
    end
    let(:block_device_mapping) do
      {
        volume_id: '333',
        volume_size: '5',
        volume_device_name: 'vda',
        delete_on_termination: 'true'
      }
    end
    let(:driver) do
      d = super()
      allow(d).to receive(:compute).and_return(compute)
      allow(d).to receive(:network).and_return(network)
      allow(d).to receive(:get_bdm).and_return(block_device_mapping)
      d
    end

    context 'a default config' do
      before(:each) do
        @expected = config.merge(name: config[:server_name])
        @expected.delete_if { |k, _| k == :server_name }
      end

      it 'creates the server using a compute connection' do
        expect(driver.send(:create_server)).to eq(@expected)
      end
    end

    context 'a provided public key path' do
      let(:config) do
        {
          server_name: 'hello',
          image_ref: '111',
          flavor_ref: '1',
          availability_zone: nil,
          public_key_path: 'tarpals'
        }
      end
      before(:each) do
        @expected = config.merge(name: config[:server_name])
        @expected.delete_if { |k, _| k == :server_name }
      end

      it 'passes that public key path to Fog' do
        expect(driver.send(:create_server)).to eq(@expected)
      end
    end

    context 'a provided key name' do
      let(:config) do
        {
          server_name: 'hello',
          image_ref: '111',
          flavor_ref: '1',
          availability_zone: nil,
          public_key_path: 'montgomery',
          key_name: 'tarpals'
        }
      end

      before(:each) do
        @expected = config.merge(name: config[:server_name])
        @expected.delete_if { |k, _| k == :server_name }
      end

      it 'passes that key name to Fog' do
        expect(driver.send(:create_server)).to eq(@expected)
      end
    end

    context 'a provided security group' do
      let(:config) do
        {
          server_name: 'hello',
          image_ref: '111',
          flavor_ref: '1',
          availability_zone: nil,
          public_key_path: 'montgomery',
          key_name: 'tarpals',
          security_groups: ['ping-and-ssh']
        }
      end

      before(:each) do
        @expected = config.merge(name: config[:server_name])
        @expected.delete_if { |k, _| k == :server_name }
      end

      it 'passes that security group to Fog' do
        expect(driver.send(:create_server)).to eq(@expected)
      end
    end

    context 'a provided availability zone' do
      let(:config) do
        {
          server_name: 'hello',
          image_ref: '111',
          flavor_ref: '1',
          availability_zone: 'elsewhere',
          public_key_path: 'montgomery',
          key_name: 'tarpals'
        }
      end

      before(:each) do
        @expected = config.merge(name: config[:server_name])
        @expected.delete_if { |k, _| k == :server_name }
      end

      it 'passes that availability zone to Fog' do
        expect(driver.send(:create_server)).to eq(@expected)
      end
    end

    context 'image/flavor specifies id' do
      let(:config) do
        {
          server_name: 'hello',
          image_ref: '111',
          flavor_ref: '1',
          public_key_path: 'tarpals'
        }
      end

      it 'exact id match' do
        expect(servers).to receive(:create).with(name: 'hello',
                                                 image_ref: '111',
                                                 flavor_ref: '1',
                                                 availability_zone: nil,
                                                 public_key_path: 'tarpals')
        driver.send(:create_server)
      end
    end

    context 'image/flavor specifies name' do
      let(:config) do
        {
          server_name: 'hello',
          image_ref: 'fedora',
          flavor_ref: 'small',
          public_key_path: 'tarpals'
        }
      end

      it 'exact name match' do
        expect(servers).to receive(:create).with(name: 'hello',
                                                 image_ref: '222',
                                                 flavor_ref: '2',
                                                 availability_zone: nil,
                                                 public_key_path: 'tarpals')
        driver.send(:create_server)
      end
    end

    context 'image/flavor specifies regex' do
      let(:config) do
        {
          server_name: 'hello',
          # pass regex as string as yml returns string values
          image_ref: '/edo/',
          flavor_ref: '/in/',
          public_key_path: 'tarpals'
        }
      end

      it 'regex name match' do
        expect(servers).to receive(:create).with(name: 'hello',
                                                 image_ref: '222',
                                                 flavor_ref: '1',
                                                 availability_zone: nil,
                                                 public_key_path: 'tarpals')
        driver.send(:create_server)
      end
    end

    context 'network specifies id' do
      let(:config) do
        {
          server_name: 'hello',
          image_ref: '111',
          flavor_ref: '1',
          public_key_path: 'tarpals',
          network_ref: '1'
        }
      end

      it 'exact id match' do
        networks = [
          { 'net_id' => '1' }
        ]
        expect(servers).to receive(:create).with(
          name: 'hello',
          image_ref: '111',
          flavor_ref: '1',
          availability_zone: nil,
          public_key_path: 'tarpals',
          nics: networks
        )
        driver.send(:create_server)
      end
    end

    context 'network specifies name' do
      let(:config) do
        {
          server_name: 'hello',
          image_ref: '111',
          flavor_ref: '1',
          public_key_path: 'tarpals',
          network_ref: 'vlan1'
        }
      end

      it 'exact id match' do
        networks = [
          { 'net_id' => '1' }
        ]
        expect(servers).to receive(:create).with(
          name: 'hello',
          image_ref: '111',
          flavor_ref: '1',
          availability_zone: nil,
          public_key_path: 'tarpals',
          nics: networks
        )
        driver.send(:create_server)
      end
    end

    context 'multiple networks specifies id' do
      let(:config) do
        {
          server_name: 'hello',
          image_ref: '111',
          flavor_ref: '1',
          public_key_path: 'tarpals',
          network_ref: %w(1 2)
        }
      end

      it 'exact id match' do
        networks = [
          { 'net_id' => '1' },
          { 'net_id' => '2' }
        ]
        expect(servers).to receive(:create).with(
          name: 'hello',
          image_ref: '111',
          flavor_ref: '1',
          availability_zone: nil,
          public_key_path: 'tarpals',
          nics: networks
        )
        driver.send(:create_server)
      end
    end

    context 'user_data specified' do
      let(:config) do
        {
          server_name: 'hello',
          image_ref: '111',
          flavor_ref: '1',
          public_key_path: 'tarpals',
          user_data: 'cloud-init.txt'
        }
      end
      let(:data) { "#cloud-config\n" }

      before(:each) do
        allow(File).to receive(:exist?).and_return(true)
        allow(File).to receive(:open).and_return(data)
      end

      it 'passes file contents' do
        expect(servers).to receive(:create).with(
          name: 'hello',
          image_ref: '111',
          flavor_ref: '1',
          availability_zone: nil,
          public_key_path: 'tarpals',
          user_data: data
        )
        driver.send(:create_server)
      end
    end

    context 'config drive enabled' do
      let(:config) do
        {
          server_name: 'hello',
          image_ref: '111',
          flavor_ref: '1',
          public_key_path: 'tarpals',
          config_drive: true
        }
      end

      it 'enables config drive' do
        expect(servers).to receive(:create).with(
          name: 'hello',
          image_ref: '111',
          flavor_ref: '1',
          availability_zone: nil,
          public_key_path: 'tarpals',
          config_drive: true
        )
        driver.send(:create_server)
      end
    end
  end

  describe '#default_name' do
    let(:login) { 'user' }
    let(:hostname) { 'host' }

    before(:each) do
      allow(Etc).to receive(:getlogin).and_return(login)
      allow(Socket).to receive(:gethostname).and_return(hostname)
    end

    it 'generates a name' do
      expect(driver.send(:default_name)).to match(/^potatoes-user-host-(\S*)/)
    end

    context 'local node with a long hostname' do
      let(:hostname) { 'ab.c' * 20 }

      it 'limits the generated name to 63 characters' do
        expect(driver.send(:default_name).length).to be <= 63
      end
    end

    context 'node with a long hostname, username, and base name' do
      let(:login) { 'abcd' * 20 }
      let(:hostname) { 'efgh' * 20 }
      let(:instance_name) { 'ijkl' * 20 }

      it 'limits the generated name to 63 characters' do
        expect(driver.send(:default_name).length).to eq(63)
      end
    end

    context 'a login and hostname with punctuation in them' do
      let(:login) { 'some.u-se-r' }
      let(:hostname) { 'a.host-name' }
      let(:instance_name) { 'a.instance-name' }

      it 'strips out the dots to prevent bad server names' do
        expect(driver.send(:default_name)).to_not include('.')
      end

      it 'strips out all but the three hyphen separators' do
        expect(driver.send(:default_name).count('-')).to eq(3)
      end
    end

    context 'a non-login shell' do
      let(:login) { nil }

      it 'subs in a placeholder login string' do
        expect(driver.send(:default_name)).to match(/^potatoes-nologin-/)
      end
    end
  end

  describe '#server_name_prefix' do
    let(:login) { 'user' }
    let(:hostname) { 'host' }
    let(:prefix) { 'parsnip' }

    # These are still used in the "blank prefix" test
    before(:each) do
      allow(Etc).to receive(:getlogin).and_return(login)
      allow(Socket).to receive(:gethostname).and_return(hostname)
    end

    it 'generates a name with the selected prefix' do
      expect(driver.send(:server_name_prefix, prefix))
        .to match(/^parsnip-(\S*)/)
    end

    context 'very long prefix provided' do
      let(:long_prefix) { 'a' * 70 }

      it 'limits the generated name to 63 characters' do
        expect(driver.send(:server_name_prefix, long_prefix).length)
          .to be <= 63
      end
    end

    context 'a prefix with punctuation' do
      let(:bad_char_prefix) { 'pa-rsn.ip' }

      it 'strips out the dots to prevent bad server names' do
        expect(driver.send(:server_name_prefix, bad_char_prefix))
          .to_not include('.')
      end

      it 'strips out all but the one hyphen separator' do
        expect(driver.send(:server_name_prefix, bad_char_prefix)
          .count('-')).to eq(1)
      end
    end

    context 'blank prefix' do
      it 'generates fully random server name' do
        expect(driver.send(:server_name_prefix, ''))
          .to match(/potatoes-user-host-(\S*)/)
      end
    end
  end

  describe '#attach_ip_from_pool' do
    let(:server) { nil }
    let(:pool) { 'swimmers' }
    let(:ip) { '1.1.1.1' }
    let(:address) do
      double(ip: ip, fixed_ip: nil, instance_id: nil, pool: pool)
    end
    let(:compute) { double(addresses: [address]) }

    before(:each) do
      allow(driver).to receive(:attach_ip).with(server, ip).and_return('bing!')
      allow(driver).to receive(:compute).and_return(compute)
    end

    it 'determines an IP to attempt to attach' do
      expect(driver.send(:attach_ip_from_pool, server, pool)).to eq('bing!')
    end

    context 'no free addresses in the specified pool' do
      let(:address) do
        double(ip: ip, fixed_ip: nil, instance_id: nil,
               pool: 'some_other_pool')
      end

      it 'raises an exception' do
        expect { driver.send(:attach_ip_from_pool, server, pool) }.to \
          raise_error(Kitchen::ActionFailed)
      end
    end
  end

  describe '#attach_ip' do
    let(:ip) { '1.1.1.1' }
    let(:addresses) { {} }
    let(:server) do
      s = double('server')
      expect(s).to receive(:associate_address).with(ip).and_return(true)
      allow(s).to receive(:addresses).and_return(addresses)
      s
    end

    it 'associates the IP address with the server' do
      expect(driver.send(:attach_ip, server, ip)).to eq(true)
    end
  end

  describe '#get_ip' do
    let(:addresses) { nil }
    let(:public_ip_addresses) { nil }
    let(:private_ip_addresses) { nil }
    let(:ip_addresses) { nil }
    let(:parsed_ips) { [[], []] }
    let(:driver) do
      d = super()
      allow(d).to receive(:parse_ips).and_return(parsed_ips)
      d
    end
    let(:server) do
      double(addresses: addresses,
             public_ip_addresses: public_ip_addresses,
             private_ip_addresses: private_ip_addresses,
             ip_addresses: ip_addresses,
             wait_for: { duration: 0 })
    end

    context 'both public and private IPs' do
      let(:public_ip_addresses) { %w(1::1 1.2.3.4) }
      let(:private_ip_addresses) { %w(5.5.5.5) }
      let(:parsed_ips) { [%w(1.2.3.4), %w(5.5.5.5)] }

      it 'returns a public IPv4 address' do
        expect(driver.send(:get_ip, server)).to eq('1.2.3.4')
      end
    end

    context 'only public IPs' do
      let(:public_ip_addresses) { %w(4.3.2.1 2::1) }
      let(:parsed_ips) { [%w(4.3.2.1), []] }

      it 'returns a public IPv4 address' do
        expect(driver.send(:get_ip, server)).to eq('4.3.2.1')
      end
    end

    context 'only private IPs' do
      let(:private_ip_addresses) { %w(3::1 5.5.5.5) }
      let(:parsed_ips) { [[], %w(5.5.5.5)] }

      it 'returns a private IPv4 address' do
        expect(driver.send(:get_ip, server)).to eq('5.5.5.5')
      end
    end

    context 'no predictable network name' do
      let(:ip_addresses) { %w(3::1 5.5.5.5) }
      let(:parsed_ips) { [[], %w(5.5.5.5)] }

      it 'returns the first IP that matches the IP version' do
        expect(driver.send(:get_ip, server)).to eq('5.5.5.5')
      end
    end

    context 'IPs in user-defined network group' do
      let(:config) { { powervc_network_name: 'mynetwork' } }
      let(:addresses) do
        {
          'mynetwork' => [
            { 'addr' => '7.7.7.7' },
            { 'addr' => '4::1' }
          ]
        }
      end

      it 'returns a IPv4 address in user-defined network group' do
        expect(driver.send(:get_ip, server)).to eq('7.7.7.7')
      end
    end

    context 'when a floating ip is provided' do
      let(:config) { { floating_ip: '1.2.3.4' } }

      it 'returns the floating ip and skips reloading' do
        allow(driver).to receive(:config).and_return(config)

        expect(server).to_not receive(:wait_for)
        expect(driver.send(:get_ip, server)).to eq('1.2.3.4')
      end
    end

    context 'an powervc deployment without the floating IP extension' do
      before do
        allow(server).to receive(:public_ip_addresses).and_raise(
          Fog::Compute.powervc::NotFound
        )
        allow(server).to receive(:private_ip_addresses).and_raise(
          Fog::Compute.powervc::NotFound
        )
      end

      context 'both public and private IPs in the addresses hash' do
        let(:addresses) do
          {
            'public' => [{ 'addr' => '6.6.6.6' }, { 'addr' => '7.7.7.7' }],
            'private' => [{ 'addr' => '8.8.8.8' }, { 'addr' => '9.9.9.9' }]
          }
        end
        let(:parsed_ips) { [%w(6.6.6.6 7.7.7.7), %w(8.8.8.8 9.9.9.9)] }

        it 'selects the first public IP' do
          expect(driver.send(:get_ip, server)).to eq('6.6.6.6')
        end
      end

      context 'when powervc_network_name is provided' do
        let(:addresses) do
          {
            'public' => [{ 'addr' => '6.6.6.6' }, { 'addr' => '7.7.7.7' }],
            'private' => [{ 'addr' => '8.8.8.8' }, { 'addr' => '9.9.9.9' }]
          }
        end
        let(:config) { { powervc_network_name: 'public' } }

        it 'should respond with the first address from the addresses' do
          allow(driver).to receive(:config).and_return(config)

          expect(driver.send(:get_ip, server)).to eq('6.6.6.6')
        end
      end

      context 'when powervc_network_name is provided and use_ipv6 is false' do
        let(:addresses) do
          {
            'public' => [{ 'addr' => '4::1' }, { 'addr' => '7.7.7.7' }],
            'private' => [{ 'addr' => '5::1' }, { 'addr' => '9.9.9.9' }]
          }
        end
        let(:config) { { powervc_network_name: 'public' } }

        it 'should respond with the first IPv4 address from the addresses' do
          allow(driver).to receive(:config).and_return(config)

          expect(driver.send(:get_ip, server)).to eq('7.7.7.7')
        end
      end

      context 'when powervc_network_name is provided and use_ipv6 is true' do
        let(:addresses) do
          {
            'public' => [{ 'addr' => '4::1' }, { 'addr' => '7.7.7.7' }],
            'private' => [{ 'addr' => '5::1' }, { 'addr' => '9.9.9.9' }]
          }
        end
        let(:config) { { powervc_network_name: 'public', use_ipv6: true } }

        it 'should respond with the first IPv6 address from the addresses' do
          allow(driver).to receive(:config).and_return(config)

          expect(driver.send(:get_ip, server)).to eq('4::1')
        end
      end

      context 'only public IPs in the address hash' do
        let(:addresses) do
          { 'public' => [{ 'addr' => '6.6.6.6' }, { 'addr' => '7.7.7.7' }] }
        end
        let(:parsed_ips) { [%w(6.6.6.6 7.7.7.7), []] }

        it 'selects the first public IP' do
          expect(driver.send(:get_ip, server)).to eq('6.6.6.6')
        end
      end

      context 'only private IPs in the address hash' do
        let(:addresses) do
          { 'private' => [{ 'addr' => '8.8.8.8' }, { 'addr' => '9.9.9.9' }] }
        end
        let(:parsed_ips) { [[], %w(8.8.8.8 9.9.9.9)] }

        it 'selects the first private IP' do
          expect(driver.send(:get_ip, server)).to eq('8.8.8.8')
        end
      end
    end

    context 'no IP addresses whatsoever' do
      it 'raises an exception' do
        expected = Kitchen::ActionFailed
        expect { driver.send(:get_ip, server) }.to raise_error(expected)
      end
    end

    context 'when network information is not found' do
      before do
        allow(server).to receive(:wait_for).and_raise(Fog::Errors::TimeoutError)
      end

      it 'raises an exception' do
        expected = Kitchen::ActionFailed
        expect { driver.send(:get_ip, server) }.to raise_error(expected)
      end
    end
  end

  describe '#parse_ips' do
    let(:pub_v4) { %w(1.1.1.1 2.2.2.2) }
    let(:pub_v6) { %w(1::1 2::2) }
    let(:priv_v4) { %w(3.3.3.3 4.4.4.4) }
    let(:priv_v6) { %w(3::3 4::4) }
    let(:pub) { pub_v4 + pub_v6 }
    let(:priv) { priv_v4 + priv_v6 }

    context 'both public and private IPs' do
      context 'IPv4 (default)' do
        it 'returns only the v4 IPs' do
          expect(driver.send(:parse_ips, pub, priv)).to eq([pub_v4, priv_v4])
        end
      end

      context 'IPv6' do
        let(:config) { { use_ipv6: true } }

        it 'returns only the v6 IPs' do
          expect(driver.send(:parse_ips, pub, priv)).to eq([pub_v6, priv_v6])
        end
      end
    end

    context 'only public IPs' do
      let(:priv) { nil }

      context 'IPv4 (default)' do
        it 'returns only the v4 IPs' do
          expect(driver.send(:parse_ips, pub, priv)).to eq([pub_v4, []])
        end
      end

      context 'IPv6' do
        let(:config) { { use_ipv6: true } }

        it 'returns only the v6 IPs' do
          expect(driver.send(:parse_ips, pub, priv)).to eq([pub_v6, []])
        end
      end
    end

    context 'only private IPs' do
      let(:pub) { nil }

      context 'IPv4 (default)' do
        it 'returns only the v4 IPs' do
          expect(driver.send(:parse_ips, pub, priv)).to eq([[], priv_v4])
        end
      end

      context 'IPv6' do
        let(:config) { { use_ipv6: true } }

        it 'returns only the v6 IPs' do
          expect(driver.send(:parse_ips, pub, priv)).to eq([[], priv_v6])
        end
      end
    end

    context 'no IPs whatsoever' do
      let(:pub) { nil }
      let(:priv) { nil }

      context 'IPv4 (default)' do
        it 'returns empty lists' do
          expect(driver.send(:parse_ips, pub, priv)).to eq([[], []])
        end
      end

      context 'IPv6' do
        let(:config) { { use_ipv6: true } }

        it 'returns empty lists' do
          expect(driver.send(:parse_ips, nil, nil)).to eq([[], []])
        end
      end
    end
  end

  describe '#add_ohai_hint' do
    let(:state) { { hostname: 'host' } }
    let(:ssh) do
      s = double('ssh')
      allow(s).to receive(:run) { |args| args }
      s
    end
    it 'opens an SSH session to the server' do
      driver.send(:add_ohai_hint, state)
    end

    it 'opens an Winrm session to the server' do
      allow(driver).to receive(:bourne_shell?).and_return(false)
      allow(driver).to receive(:windows_os?).and_return(true)
      driver.send(:add_ohai_hint, state)
    end
  end

  describe '#disable_ssl_validation' do
    it 'turns off Excon SSL cert validation' do
      expect(driver.send(:disable_ssl_validation)).to eq(false)
    end
  end

  describe '#countdown' do
    it 'counts down to future time with 0 seconds with almost no time' do
      current = Time.now
      driver.send(:countdown, 0)
      after = Time.now
      expect(after - current).to be >= 0
      expect(after - current).to be < 10
    end

    it 'counts down to future time with 1 seconds with at least 9 seconds' do
      current = Time.now
      driver.send(:countdown, 1)
      after = Time.now
      expect(after - current).to be >= 9
    end
  end

  describe '#wait_for_server' do
    let(:config) { { server_wait: 0 } }
    let(:state) { { hostname: 'host' } }

    it 'waits for connection to be available' do
      expect(driver.send(:wait_for_server, state)).to be(nil)
    end

    it 'Fails when calling transport but still destroys the created system' do
      allow(instance.transport).to receive(:connection).and_raise(ArgumentError)
      expect(driver).to receive(:destroy)

      expect { driver.send(:wait_for_server, state) }
        .to raise_error(ArgumentError)
    end
  end

  describe '#get_bdm' do
    let(:logger) { Logger.new(logged_output) }
    let(:config) do
      {
        powervc_username: 'a',
        powervc_api_key: 'b',
        powervc_auth_url: 'http://',
        powervc_tenant: 'me',
        powervc_region: 'ORD',
        powervc_service_name: 'stack',
        image_ref: '22',
        flavor_ref: '33',
        public_key_path: '/tmp',
        username: 'admin',
        port: '2222',
        server_name: 'puppy',
        server_name_prefix: 'parsnip',
        private_key_path: '/path/to/id_rsa',
        floating_ip_pool: 'swimmers',
        floating_ip: '11111',
        network_ref: '0xCAFFE',
        block_device_mapping: {
          volume_id: '55',
          volume_size: '5',
          device_name: 'vda',
          delete_on_termination: true
        }
      }
    end
    it 'returns just the BDM config' do
      expect(driver.send(:get_bdm, config)).to eq(config[:block_device_mapping])
    end
  end

  describe '#config_server_name' do
    let(:config) do
      {
        server_name_prefix: 'parsnip'
      }
    end

    it 'returns random string prefixed by servername_prefix attribute' do
      expect(driver.send(:config_server_name)).to include('parsnip')
    end
  end
end
