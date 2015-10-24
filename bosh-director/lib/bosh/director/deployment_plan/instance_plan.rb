module Bosh
  module Director
    module DeploymentPlan
      class InstancePlan
        def initialize(attrs)
          @existing_instance = attrs.fetch(:existing_instance)
          @desired_instance = attrs.fetch(:desired_instance)
          @instance = attrs.fetch(:instance)
          @network_plans = attrs.fetch(:network_plans, [])
          @skip_drain = attrs.fetch(:skip_drain, false)
          @recreate_deployment = attrs.fetch(:recreate_deployment, false)
          @logger = attrs.fetch(:logger, Config.logger)
          @dns_manager = DnsManager.create
        end

        attr_reader :desired_instance, :existing_instance, :instance, :skip_drain, :recreate_deployment

        attr_accessor :network_plans

        ##
        # @return [Boolean] returns true if the any of the expected specifications
        #   differ from the ones provided by the VM
        def changed?
          !changes.empty?
        end

        ##
        # @return [Set<Symbol>] returns a set of all of the specification differences
        def changes
          return @changes if @changes

          @changes = Set.new
          @changes << :restart if needs_restart?
          @changes << :recreate if needs_recreate?
          @changes << :cloud_properties if instance.cloud_properties_changed?
          @changes << :vm_type if vm_type_changed?
          @changes << :stemcell if stemcell_changed?
          @changes << :env if env_changed?
          @changes << :network if networks_changed?
          @changes << :packages if instance.packages_changed?
          @changes << :persistent_disk if persistent_disk_changed?
          @changes << :configuration if instance.configuration_changed?
          @changes << :job if instance.job_changed?
          @changes << :state if state_changed?
          @changes << :dns if dns_changed?
          @changes << :trusted_certs if instance.trusted_certs_changed?
          @changes
        end

        def persistent_disk_changed?
          if @existing_instance && obsolete?
            return !@existing_instance.persistent_disk.nil?
          end

          job = @instance.job
          new_disk_size = job.persistent_disk_type ? job.persistent_disk_type.disk_size : 0
          new_disk_cloud_properties = job.persistent_disk_type ? job.persistent_disk_type.cloud_properties : {}
          changed = new_disk_size != disk_size
          log_changes(__method__, "disk size: #{disk_size}", "disk size: #{new_disk_size}", @existing_instance) if changed
          return true if changed

          changed = new_disk_size != 0 && new_disk_cloud_properties != disk_cloud_properties
          log_changes(__method__, disk_cloud_properties, new_disk_cloud_properties, @existing_instance) if changed
          changed
        end


        def needs_restart?
          @desired_instance.virtual_state == 'restart'
        end

        def needs_recreate?
          if @recreate_deployment
            @logger.debug("#{__method__} job deployment is configured with \"recreate\" state")
            true
          else
            @desired_instance.virtual_state == 'recreate'
          end
        end

        def networks_changed?
          desired_plans = network_plans.select(&:desired?)
          obsolete_plans = network_plans.select(&:obsolete?)
          if obsolete_plans.any? || desired_plans.any?
            network_settings_for_previous_reservations = new? ? {} : @existing_instance.vm.apply_spec['networks']

            log_changes(__method__, network_settings_for_previous_reservations, network_settings.to_hash, @existing_instance)
            true
          else
            false
          end
        end

        def state_changed?
          if desired_instance.state == 'detached' &&
            existing_instance.state != desired_instance.state
            @logger.debug("Instance '#{instance}' needs to be detached")
            return true
          end

          if instance.state == 'stopped' && instance.current_job_state == 'running' ||
            instance.state == 'started' && instance.current_job_state != 'running'
            @logger.debug("Instance state is '#{instance.state}' and agent reports '#{instance.current_job_state}'")
            return true
          end

          false
        end

        def dns_changed?
          return false unless @dns_manager.dns_enabled?

          network_settings.dns_record_info.any? do |name, ip|
            not_found = @dns_manager.find_dns_record(name, ip).nil?
            @logger.debug("#{__method__} The requested dns record with name '#{name}' and ip '#{ip}' was not found in the db.") if not_found
            not_found
          end
        end

        def mark_desired_network_plans_as_existing
          network_plans.select(&:desired?).each { |network_plan| network_plan.existing = true }
        end

        def release_obsolete_network_plans
          network_plans.delete_if(&:obsolete?)
        end

        def release_all_network_plans
          network_plans.clear
        end

        def obsolete?
          desired_instance.nil?
        end

        def new?
          existing_instance.nil?
        end

        def existing?
          !new? && !obsolete?
        end

        def network_settings
          desired_reservations = network_plans
                                   .reject(&:obsolete?)
                                   .map { |network_plan| network_plan.reservation }

          DeploymentPlan::NetworkSettings.new(
            @instance.job.name,
            @instance.model.deployment.name,
            @instance.job.default_network,
            desired_reservations,
            @instance.current_state,
            @instance.availability_zone,
            @instance.index,
            @instance.uuid,
            @dns_manager
          )
        end

        def network_settings_hash
          if obsolete? || network_settings.to_hash.empty?
            @existing_instance.apply_spec['networks']
          else
            network_settings.to_hash
          end
        end

        def network_addresses
          network_settings.network_addresses
        end

        def needs_shutting_down?
          return true if obsolete?

            vm_type_changed? ||
            stemcell_changed? ||
            env_changed? ||
            needs_recreate?
        end

        def find_existing_reservation_for_network(network)
          @instance.existing_network_reservations.find_for_network(network)
        end

        def desired_az_name
          @desired_instance.az ? @desired_instance.az.name : nil
        end

        def network_plan_for_network(network)
          @network_plans.find { |plan| plan.reservation.network == network }
        end

        private

        def env_changed?
          job = @instance.job

          if @existing_instance && @existing_instance.env && job.env.spec != @existing_instance.env
            log_changes(__method__, @existing_instance.vm.env, job.env.spec, @existing_instance)
            return true
          end
          false
        end

        def stemcell_changed?
          if @existing_instance && @instance.stemcell.name != @existing_instance.apply_spec['stemcell']['name']
            log_changes(__method__, @existing_instance.apply_spec['stemcell']['name'], @instance.stemcell.name, @existing_instance)
            return true
          end

          if @existing_instance && @instance.stemcell.version != @existing_instance.apply_spec['stemcell']['version']
            log_changes(__method__, "version: #{@existing_instance.apply_spec['stemcell']['version']}", "version: #{@instance.stemcell.version}", @existing_instance)
            return true
          end

          false
        end

        def vm_type_changed?
          if @existing_instance && @instance.vm_type.spec != @existing_instance.apply_spec['vm_type']
            log_changes(__method__, @existing_instance.apply_spec['vm_type'], @instance.job.vm_type.spec, @existing_instance)
            return true
          end
          false
        end

        def log_changes(method_sym, old_state, new_state, instance)
          @logger.debug("#{method_sym} changed FROM: #{old_state} TO: #{new_state} on instance #{instance}")
        end

        def disk_size
          if @instance.model.nil?
            raise DirectorError, "Instance `#{@instance}' model is not bound"
          end

          if @instance.model.persistent_disk
            @instance.model.persistent_disk.size
          else
            0
          end
        end

        def disk_cloud_properties
          if @instance.model.nil?
            raise DirectorError, "Instance `#{@instance}' model is not bound"
          end

          if @instance.model.persistent_disk
            @instance.model.persistent_disk.cloud_properties
          else
            {}
          end
        end
      end
    end
  end
end