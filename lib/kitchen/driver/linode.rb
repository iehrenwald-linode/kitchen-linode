# -*- encoding: utf-8 -*-
#
# Author:: Brett Taylor (<btaylor@linode.com>)
#
# Copyright (C) 2015, Brett Taylor
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'kitchen'
require 'fog/linode'
require 'retryable'
require_relative 'linode_version'

module Kitchen

  module Driver
    # Linode driver for Kitchen.
    #
    # @author Brett Taylor <btaylor@linode.com>
    class Linode < Kitchen::Driver::Base
      kitchen_driver_api_version 2
      plugin_version Kitchen::Driver::LINODE_VERSION

      default_config :username, 'root'
      default_config :password, nil
      default_config :label, nil
      default_config :hostname, nil
      default_config :image, nil
      default_config :region, 'us-east'
      default_config :type, 'g6-nanode-1'
      default_config :kernel, 'linode/grub2'
      default_config :api_retries, 5

      default_config :sudo, true
      default_config :ssh_timeout, 600

      default_config :private_key_path do
        %w(id_rsa).map do |k|
          f = File.expand_path("~/.ssh/#{k}")
          f if File.exist?(f)
        end.compact.first
      end
      default_config :public_key_path do |driver|
        driver[:private_key_path] + '.pub' if driver[:private_key_path]
      end

      default_config :linode_token, ENV['LINODE_TOKEN']

      required_config :linode_token
      required_config :private_key_path
      required_config :public_key_path

      def initialize(config)
        super
        # callback to check if we can retry
        retry_exception_callback = lambda do |exception|
          if exception.class == Excon::Error::TooManyRequests
            # add a random value between 2 and 20 to the sleep to splay retries
            sleep_time = exception.response.headers["Retry-After"].to_i + rand(2..20)
            warn("Rate limit encountered, sleeping #{sleep_time} seconds for it to expire.")
            sleep(sleep_time)
          end
        end
        log_method = lambda do |retries, exception|
          warn("[Attempt ##{retries}] Retrying because [#{exception.class}]")
        end
        # configure to retry on timeouts and rate limits by default
        Retryable.configure do |retry_config|
          retry_config.log_method   = log_method
          retry_config.exception_cb = retry_exception_callback
          retry_config.on           = [Excon::Error::Timeout,
                                       Excon::Error::RequestTimeout,
                                       Excon::Error::TooManyRequests]
          retry_config.tries        = config[:api_retries]
          retry_config.sleep        = lambda { |n| 2**n }  # sleep 1, 2, 4, etc. each try
        end
      end

      def create(state)
        # create and boot server
        config_hostname
        config_label
        set_password

        if state[:linode_id]
          info "Linode <#{state[:linode_id]}, #{state[:linode_label]}> already exists."
          return
        end

        server = create_server

        # assign the machine id for reference in other commands
        state[:linode_id] = server.id
        state[:linode_label] = server.label
        state[:hostname] = server.ipv4[0]
        info("Linode <#{state[:linode_id]}, #{state[:linode_label]}> created.")
        info("Waiting for linode to boot...")
        server.wait_for { server.status == 'running' }
        info("Linode <#{state[:linode_id]}, #{state[:linode_label]}> ready.")
        setup_ssh(state) if bourne_shell?
      rescue Fog::Errors::Error, Excon::Errors::Error => ex
        error("Failed to create server: #{ex.class} - #{ex.message}")
        raise ActionFailed, ex.message
      end

      def destroy(state)
        return if state[:linode_id].nil?
        begin
          Retryable.retryable do
            server = compute.servers.get(state[:linode_id])
            server.destroy
          end
          info("Linode <#{state[:linode_id]}, #{state[:linode_label]}> destroyed.")
        rescue Excon::Error::NotFound
          info("Linode <#{state[:linode_id]}, #{state[:linode_label]}> not found.")
        end
        state.delete(:linode_id)
        state.delete(:linode_label)
        state.delete(:pub_ip)
      end

      private

      def compute
        Fog::Compute.new(provider: :linode, linode_token: config[:linode_token])
      end

      def get_region
        region = nil
        Retryable.retryable do
          region = compute.regions.find { |region| region.id == config[:region] }
        end

        if region.nil?
          fail(UserError, "No match for region: #{config[:region]}")
        end
        info "Got region: #{region.id}..."
        return region.id
      end

      def get_type
        type = nil
        Retryable.retryable do
          type = compute.types.find { |type| type.id == config[:type] }
        end

        if type.nil?
          fail(UserError, "No match for type: #{config[:type]}")
        end
        info "Got type: #{type.id}..."
        return type.id
      end

      def get_image
        if config[:image].nil?
          image_id = instance.platform.name
        else
          image_id = config[:image]
        end
        image = nil
        Retryable.retryable do
          image = compute.images.find { |image| image.id == image_id }
        end

        if image.nil?
          fail(UserError, "No match for image: #{config[:image]}")
        end
        info "Got image: #{image.id}..."
        return image.id
      end

      def get_kernel
        kernel = nil
        Retryable.retryable do
          kernel = compute.kernels.find { |kernel| kernel.id == config[:kernel] }
        end

        if kernel.nil?
          fail(UserError, "No match for kernel: #{config[:kernel]}")
        end
        info "Got kernel: #{kernel.id}..."
        return kernel.id
      end

      # generate a unique label
      def generate_unique_label
        # Try to generate a unique suffix and make sure nothing else on the account
        # has the same label.
        # The iterator is a randomized list from 0 to 99.
        for suffix in (0..99).to_a.sample(100)
          label = "#{config[:label]}#{'%02d' % suffix}"
          Retryable.retryable do
            if compute.servers.find { |server| server.label == label }.nil?
              return label
            end
          end
        end
        # if we're here that means we couldn't make a unique label with the given prefix
        # yell at the user that they need to clean up their account.
        error("Unable to generate a unique label with prefix #{config[:label]}. Might need to cleanup your account.")
        fail(UserError, "Unable to generate a unique label.")
      end

      def create_server
        region = get_region
        type = get_type
        image = get_image
        kernel = get_kernel
        # callback to check if we can retry
        create_exception_callback = lambda do |exception|
          if not exception.response.body.include? "Label must be unique"
            # we want to float this to the user instead of retrying
            raise exception
          end
          info("Got [#{exception.class}] due to non-unique label when creating server.")
          info("Will try again with a new label if we can.")
        end
        # submit new linode request
        Retryable.retryable(
          on: [Excon::Error::BadRequest],
          tries: config[:api_retries],
          exception_cb: create_exception_callback,
          log_method: proc {}
        ) do
          # This will retry if we get a response that the label must be
          # unique. We wrap both of these in a retry so we generate a
          # new label when we try again.
          label = generate_unique_label
          info("Creating Linode - #{label}")
          Retryable.retryable do
            compute.servers.create(
              :region => region,
              :type => type,
              :label => label,
              :image => image,
              :kernel => kernel,
              :username => config[:username],
              :root_pass => config[:password]
            )
          end
        end
      end

      def setup_ssh(state)
        set_ssh_keys
        state[:ssh_key] = config[:private_key_path]
        do_ssh_setup(state, config)
      end

      def do_ssh_setup(state, config)
        info "Setting up SSH access for key <#{config[:public_key_path]}>"
        info "Connecting <#{config[:username]}@#{state[:hostname]}>..."
        ssh = Fog::SSH.new(state[:hostname],
                           config[:username],
                           :password => config[:password],
                           :timeout => config[:ssh_timeout])
        pub_key = open(config[:public_key_path]).read
        shortname = "#{config[:hostname].split('.')[0]}"
        hostsfile = "127.0.0.1 #{config[:hostname]} #{shortname} localhost\n::1 #{config[:hostname]} #{shortname} localhost"
        @max_interval = 60
        @max_retries = 10
        @retries = 0
        begin
          ssh.run([
            %(echo "#{hostsfile}" > /etc/hosts),
            %(hostnamectl set-hostname #{config[:hostname]}),
            %(mkdir .ssh),
            %(echo "#{pub_key}" >> ~/.ssh/authorized_keys),
            %(passwd -l #{config[:username]})
          ])
        rescue
          @retries ||= 0
          if @retries < @max_retries
            info "Retrying connection..."
            sleep [2**(@retries - 1), @max_interval].min
            @retries += 1
            retry
          else
            raise
          end
        end
        info "Done setting up SSH access."
      end

      # Set the proper server name in the config
      def config_label
        if config[:label]
          config[:label] = "kitchen-#{config[:label]}-#{instance.name}-#{Time.now.to_i.to_s}"
        else
          if ENV["JOB_NAME"]
            # use jenkins job name variable. "kitchen_root" turns into "workspace" which is uninformative.
            jobname = ENV["JOB_NAME"]
          elsif ENV["GITHUB_JOB"]
            jobname = ENV["GITHUB_JOB"]
          elsif config[:kitchen_root]
            jobname = File.basename(config[:kitchen_root])
          else
            jobname = 'job'
          end
          config[:label] = "kitchen-#{jobname}-#{instance.name}-#{Time.now.to_i.to_s}".tr(" /", "_")
        end

        # cut to fit Linode 32 character maximum
        # we trim to 30 so we can add a random 2 digit suffix on later
        if config[:label].is_a?(String) && config[:label].size >= 30
          config[:label] = "#{config[:label][0..29]}"
        end
      end

      # Set the proper server hostname
      def config_hostname
        if config[:hostname].nil?
          if config[:label]
            config[:hostname] = "#{config[:label]}"
          else
            config[:hostname] = "#{instance.name}"
          end
        end
      end

      # ensure a password is set
      def set_password
        if config[:password].nil?
          config[:password] = [*('a'..'z'),*('A'..'Z'),*('0'..'9')].sample(15).join
        end
      end

      # set ssh keys
      def set_ssh_keys
        if config[:private_key_path]
          config[:private_key_path] = File.expand_path(config[:private_key_path])
        end
        if config[:public_key_path]
          config[:public_key_path] = File.expand_path(config[:public_key_path])
        end
      end
    end
  end
end
