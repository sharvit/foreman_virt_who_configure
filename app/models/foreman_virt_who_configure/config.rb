module ForemanVirtWhoConfigure
  class Config < ActiveRecord::Base
    PERMITTED_PARAMS = [
      :interval, :organization_id, :compute_resource_id, :whitelist, :blacklist, :listing_mode, :hypervisor_id,
      :current_step, :hypervisor_type, :hypervisor_server, :hypervisor_username, :hypervisor_password, :debug,
      :satellite_url
    ]
    include Authorizable
    audited
    validates_lengths_from_database

    UNLIMITED = 0
    WHITELIST = 1
    BLACKLIST = 2

    WIZARD_STEPS = {
      'general_information' => _('General information'),
      'schedule' => _('Schedule'),
      'connection' => _('Connection')
    }

    HYPERVISOR_IDS = [ 'hostname', 'uuid', 'hwuuid' ]

    HYPERVISOR_TYPES = {
      'esx' => 'VMware vSphere / vCenter (esx)',
      'rhevm' => 'Red Hat Virtualization Hypervisor (rhevm)',
      # 'vdsm' => 'Red Hat Enterprise Linux Hypervisor (vdsm)',
      'hyperv' => 'Microsoft Hyper-V (hyperv)',
      'xen' => 'XenServer (xen)',
      'libvirt' => 'libvirt'
    }

    HYPERVISOR_DEFAULT_TYPE = 'esx'

    include Encryptable
    encrypts :hypervisor_password

    belongs_to :compute_resource
    belongs_to :organization

    # service user used by virt-who to report back
    belongs_to :service_user

    scoped_search :on => :interval, :complete_value => true
    # TODO add more related objects and attributes

    # compatibility layer for 1.11 - pre strong params patch
    if self.respond_to?(:attr_accessible)
      attr_accessible *PERMITTED_PARAMS
    end

    attr_writer :current_step

    after_create :create_service_user
    after_destroy :destroy_service_user

    def create_service_user
      password = User.random_password
      service_user = self.build_service_user
      user = service_user.build_user
      user.auth_source = AuthSourceHiddenWithAuthentication.first
      user.password = password
      user.login = "virt_who_reporter_#{self.id}"
      user.organizations = [ self.organization ]
      user.roles = [ Role.where(:name => 'Virt-who Reporter') ]
      user.valid? # to trigger password hashing
      user.save!(:validate => false)

      service_user.encrypted_password = password
      service_user.save!

      self.update_attribute :service_user_id, service_user.id
    end

    def destroy_service_user
      # skip validation that prevents hidden user deletion
      user = service_user.user
      service_user.destroy
      user.delete
    end

    # mapping of supported CR types
    # case config.compute_resource
    #   when Foreman::Model::Libvirt
    #     'libvirt'
    #   when Foreman::Model::Vmware
    #     'esx'
    #   when Foreman::Model::Ovirt
    #     'rhevm'
    #   else
    #     raise 'unsupported compute resource type'
    # end

    # Foreman 1.11 specifics, can be removed later, otherwise when string does not start with "encrypts" prefix
    # we get 500 when we try to create log message that relies on name method
    def name
      title
    end

    def title
      compute_resource ? compute_resource.name : hypervisor_server
    end

    # TODO convert to hours if needed
    def humanized_interval
      _("every %s minutes") % self.interval
    end

    def step_to_i(step_name)
      steps.index(step_name) + 1
    end

    def steps
      WIZARD_STEPS.keys
    end

    def current_step
      @current_step || steps.first
    end

    def previous_step
      steps[steps.index(current_step) - 1]
    end

    def next_step
      steps[steps.index(current_step) + 1]
    end

    def rewind_step
      @current_step = previous_step
    end

    def first_step?
      current_step == steps.first
    end

    def last_step?
      current_step == steps.last
    end

    def step_index
      wizard_completed? ? steps.index(steps.last) : steps.index(current_step) + 1
    end

    def wizard_completed?
      new_record? && current_step.blank?
    end

    def virt_who_config_file
      generator = OutputGenerator.new(self)
      if generator.ready_for_virt_who_output?
        generator.virt_who_output
      else
        generator.missing_virt_who_input_messages.join("\n")
      end
    end
  end
end
