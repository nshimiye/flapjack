#!/usr/bin/env ruby

require 'digest'

require 'swagger/blocks'

require 'zermelo/records/redis'

require 'flapjack/data/validators/id_validator'

require 'flapjack/data/condition'
require 'flapjack/data/medium'
require 'flapjack/data/scheduled_maintenance'
require 'flapjack/data/state'
require 'flapjack/data/tag'
require 'flapjack/data/unscheduled_maintenance'

require 'flapjack/gateways/jsonapi/data/associations'

module Flapjack

  module Data

    class Check

      include Zermelo::Records::Redis
      include ActiveModel::Serializers::JSON
      self.include_root_in_json = false
      include Flapjack::Gateways::JSONAPI::Data::Associations
      include Swagger::Blocks

      define_attributes :name                  => :string,
                        :enabled               => :boolean,
                        :ack_hash              => :string,
                        :initial_failure_delay => :integer,
                        :repeat_failure_delay  => :integer,
                        :notification_count    => :integer,
                        :condition             => :string,
                        :failing               => :boolean

      index_by :enabled, :failing
      unique_index_by :name, :ack_hash

      # TODO validate uniqueness of :name, :ack_hash

      # TODO verify that callbacks are called no matter which side
      # of the association fires the initial event
      has_and_belongs_to_many :tags, :class_name => 'Flapjack::Data::Tag',
        :inverse_of => :checks, :after_add => :recalculate_routes,
        :after_remove => :recalculate_routes,
        :related_class_names => ['Flapjack::Data::Rule', 'Flapjack::Data::Route']

      def recalculate_routes(*t)
        self.routes.destroy_all
        return if self.tags.empty?

        # find all rules matching these tags
        generic_rule_ids = Flapjack::Data::Rule.intersect(:has_tags => false).ids

        tag_ids = self.tags.ids

        tag_rules_ids = Flapjack::Data::Tag.intersect(:id => tag_ids).
          associated_ids_for(:rules)

        return if tag_rules_ids.empty?

        all_rules_for_tags_ids = Set.new(tag_rules_ids.values).flatten

        return if all_rules_for_tags_ids.empty?

        rule_tags_ids = Flapjack::Data::Rule.intersect(:id => all_rules_for_tags_ids).
          associated_ids_for(:tags)

        rule_tags_ids.delete_if {|rid, tids| (tids - tag_ids).size > 0 }

        rule_ids = rule_tags_ids.keys | generic_rule_ids.to_a

        return if rule_ids.empty?

        Flapjack::Data::Rule.intersect(:id => rule_ids).each do |r|
          route = Flapjack::Data::Route.new(:is_alerting => false,
            :conditions_list => r.conditions_list)
          route.save

          r.routes << route
          self.routes << route
        end
      end

      has_sorted_set :scheduled_maintenances,
        :class_name => 'Flapjack::Data::ScheduledMaintenance',
        :key => :start_time, :order => :desc, :inverse_of => :check

      has_sorted_set :unscheduled_maintenances,
        :class_name => 'Flapjack::Data::UnscheduledMaintenance',
        :key => :start_time, :order => :desc, :inverse_of => :check

      has_sorted_set :states, :class_name => 'Flapjack::Data::State',
        :key => :created_at, :order => :desc, :inverse_of => :check

      # shortcut to expose the latest of the above to the API
      has_one :current_state, :class_name => 'Flapjack::Data::State',
        :inverse_of => :current_check

      has_sorted_set :latest_notifications, :class_name => 'Flapjack::Data::State',
        :key => :created_at, :order => :desc, :inverse_of => :latest_notifications_check,
        :after_remove => :destroy_states

      def destroy_states(*st)
        # won't be deleted if still referenced elsewhere -- see the State
        # before_destroy callback
        st.map(&:destroy)
      end

      has_and_belongs_to_many :contacts, :class_name => 'Flapjack::Data::Contact',
        :inverse_of => :checks

      # the following associations are used internally, for the notification
      # and alert queue inter-pikelet workflow
      has_one :most_severe, :class_name => 'Flapjack::Data::State',
        :inverse_of => :most_severe_check, :after_clear => :destroy_states

      has_many :notifications, :class_name => 'Flapjack::Data::Notification',
        :inverse_of => :check

      has_many :alerts, :class_name => 'Flapjack::Data::Alert',
        :inverse_of => :check

      has_and_belongs_to_many :routes, :class_name => 'Flapjack::Data::Route',
        :inverse_of => :checks

      has_and_belongs_to_many :alerting_media, :class_name => 'Flapjack::Data::Medium',
        :inverse_of => :alerting_checks
      # end internal associations

      validates :name, :presence => true
      validates :enabled, :inclusion => {:in => [true, false]}

      validates :condition, :presence => true, :unless => proc {|c| c.failing.nil? }
      validates :failing, :inclusion => {:in => [true, false]},
        :unless => proc {|c| c.condition.nil? }

      validates :initial_failure_delay, :allow_nil => true,
        :numericality => {:greater_than_or_equal_to => 0, :only_integer => true}

      validates :repeat_failure_delay, :allow_nil => true,
        :numericality => {:greater_than_or_equal_to => 0, :only_integer => true}

      before_validation :create_ack_hash
      validates :ack_hash, :presence => true

      validates_with Flapjack::Data::Validators::IdValidator

      attr_accessor :count

      def self.jsonapi_type
        self.name.demodulize.underscore
      end

      swagger_schema :Check do
        key :required, [:id, :type, :name, :enabled, :failing]
        property :id do
          key :type, :string
          key :format, :uuid
        end
        property :type do
          key :type, :string
          key :enum, [Flapjack::Data::Check.jsonapi_type.downcase]
        end
        property :name do
          key :type, :string
        end
        property :enabled do
          key :type, :boolean
          key :enum, [true, false]
        end
        property :failing do
          key :type, :boolean
          key :enum, [true, false]
        end
        property :condition do
          key :type, :string
          key :enum, Flapjack::Data::Condition.healthy.keys +
                       Flapjack::Data::Condition.unhealthy.keys
        end
        property :links do
          key :"$ref", :CheckLinks
        end
      end

      swagger_schema :CheckLinks do
        key :required, [:self, :alerting_media, :contacts, :current_state,
                        :latest_notifications, :scheduled_maintenance,
                        :states, :tags, :unscheduled_maintenances]
        property :self do
          key :type, :string
          key :format, :url
        end
        property :alerting_media do
          key :type, :string
          key :format, :url
        end
        property :contacts do
          key :type, :string
          key :format, :url
        end
        property :current_state do
          key :type, :string
          key :format, :url
        end
        property :latest_notifications do
          key :type, :string
          key :format, :url
        end
        property :scheduled_maintenances do
          key :type, :string
          key :format, :url
        end
        property :states do
          key :type, :string
          key :format, :url
        end
        property :tags do
          key :type, :string
          key :format, :url
        end
        property :unscheduled_maintenances do
          key :type, :string
          key :format, :url
        end
      end

      swagger_schema :CheckCreate do
        key :required, [:type, :name, :enabled]
        property :id do
          key :type, :string
          key :format, :uuid
        end
        property :type do
          key :type, :string
          key :enum, [Flapjack::Data::Check.jsonapi_type.downcase]
        end
        property :name do
          key :type, :string
        end
        property :enabled do
          key :type, :boolean
          key :enum, [true, false]
        end
        property :links do
          key :"$ref", :CheckChangeLinks
        end
      end

      swagger_schema :CheckUpdate do
        key :required, [:id, :type]
        property :id do
          key :type, :string
          key :format, :uuid
        end
        property :type do
          key :type, :string
          key :enum, [Flapjack::Data::Check.jsonapi_type.downcase]
        end
        property :name do
          key :type, :string
        end
        property :enabled do
          key :type, :boolean
          key :enum, [true, false]
        end
        property :links do
          key :"$ref", :CheckChangeLinks
        end
      end

      swagger_schema :CheckChangeLinks do
        property :scheduled_maintenances do
          key :"$ref", :jsonapi_UnscheduledMaintenancesLinkage
        end
        property :tags do
          key :"$ref", :jsonapi_TagsLinkage
        end
        property :unscheduled_maintenances do
          key :"$ref", :jsonapi_ScheduledMaintenancesLinkage
        end
      end

      def self.jsonapi_methods
        [:post, :get, :patch, :delete]
      end

      def self.jsonapi_attributes
        {
          :post  => [:name, :enabled],
          :get   => [:name, :enabled, :ack_hash, :failing, :condition],
          :patch => [:name, :enabled]
        }
      end

      def self.jsonapi_extra_locks
        {
          :post   => [],
          :get    => [],
          :patch  => [],
          :delete => []
        }
      end

      # read-only by definition; singular & multiple hashes of
      # method_name => [other classes to lock]
      def self.jsonapi_linked_methods
        {
          :singular => {
            :current_unscheduled_maintenance => [Flapjack::Data::UnscheduledMaintenance]
          },
          :multiple => {
            :current_scheduled_maintenances => [Flapjack::Data::ScheduledMaintenance]
          }
        }
      end

      def self.jsonapi_associations
        {
          :read_only  => {
            :singular => [:current_state],
            :multiple => [:alerting_media, :contacts, :latest_notifications,
                          :states]
          },
          :read_write => {
            :singular => [],
            :multiple => [:scheduled_maintenances, :tags,
                          :unscheduled_maintenances]
          }
        }
      end

      def in_scheduled_maintenance?(t = Time.now)
        return false if scheduled_maintenances_at(t).empty?
        no_longer_alerting
        true
      end

      def current_scheduled_maintenances
        csm = scheduled_maintenances_at(Time.now).all
        return [] if csm.empty?
        no_longer_alerting
        csm
      end

      def in_unscheduled_maintenance?(t = Time.now)
        !unscheduled_maintenances_at(t).empty?
      end

      def current_unscheduled_maintenance
        unscheduled_maintenances_at(Time.now).all.first
      end

      # TODO allow summary to be changed as part of the termination
      def end_scheduled_maintenance(sched_maint, at_time)
        at_time = Time.at(at_time) unless at_time.is_a?(Time)

        if sched_maint.start_time >= at_time
          # the scheduled maintenance period is in the future
          self.scheduled_maintenances.delete(sched_maint)
          sched_maint.destroy
          return true
        elsif sched_maint.end_time >= at_time
          # it spans the current time, so we'll stop it at that point
          sched_maint.end_time = at_time
          sched_maint.save
          self.routes.intersect(:is_alerting => true).each do |route|
            route.is_alerting = false
            route.save
          end
          return true
        end

        false
      end

      def set_unscheduled_maintenance(unsched_maint, options = {})
        current_time = Time.now

        self.class.lock(Flapjack::Data::UnscheduledMaintenance,
          Flapjack::Data::Route, Flapjack::Data::State) do

          # time_remaining
          if (unsched_maint.end_time - current_time) > 0
            self.clear_unscheduled_maintenance(unsched_maint.start_time)
          end

          self.unscheduled_maintenances << unsched_maint

          # # TODO maybe add an ack action to the event state directly, uless this is the
          # # result of one
          # if options[:create_state].is_a?(TrueClass)
          #   last_state = self.states.last
          #   ack_state = Flapjack::Data::State.new
          #   # TODO set state data
          #   ack_state.save
          #   self.states << ack_state
          # end

          self.routes.intersect(:is_alerting => true).each do |route|
            route.is_alerting = false
            route.save
          end
        end
      end

      def clear_unscheduled_maintenance(end_time)
        Flapjack::Data::UnscheduledMaintenance.lock do
          t = Time.now
          start_range = Zermelo::Filters::IndexRange.new(nil, t, :by_score => true)
          end_range   = Zermelo::Filters::IndexRange.new(t, nil, :by_score => true)
          unsched_maints = self.unscheduled_maintenances.intersect(:start_time => start_range,
            :end_time => end_range)
          unsched_maints_count = unsched_maints.empty?
          unless unsched_maints_count == 0
            # FIXME log warning if count > 1
            unsched_maints.each do |usm|
              usm.end_time = end_time
              usm.save
            end
          end
        end
      end

      # candidate rules are all rules for which
      #   (rule.tags.ids - check.tags.ids).empty?
      # this includes generic rules, i.e. ones with no tags

      # A generic rule in Flapjack v2 means that it applies to all checks, not
      # just all checks the contact is separately regeistered for, as in v1.
      # These are not automatically created for users any more, but can be
      # deliberately configured.

      # returns array with two hashes [{contact_id => Set<rule_ids>},
      #   {rule_id => Set<route_ids>}]

      def rule_ids_and_route_ids(opts = {})
        severity = opts[:severity]

        r_ids = self.routes.ids

        Flapjack.logger.debug {
          "severity: #{severity}\n" \
          "Matching routes before severity (#{r_ids.size}): #{r_ids.inspect}"
        }
        return [{}, {}] if r_ids.empty?

        check_routes = self.routes

        unless severity.nil? || Flapjack::Data::Condition.healthy.include?(severity)
          check_routes = check_routes.
            intersect(:conditions_list => [nil, /(?:^|,)#{severity}(?:,|$)/])
        end

        route_ids = check_routes.ids
        return [{}, {}] if route_ids.empty?

        Flapjack.logger.debug {
          "Matching routes after severity (#{route_ids.size}): #{route_ids.inspect}"
        }

        route_ids_by_rule_id = Flapjack::Data::Route.intersect(:id => route_ids).
          associated_ids_for(:rule, :inversed => true)

        rule_ids = route_ids_by_rule_id.keys

        Flapjack.logger.debug {
          "Matching rules for routes (#{rule_ids.size}): #{rule_ids.inspect}"
        }

        # TODO could maybe also eliminate rules with no media here?
        rule_ids_by_contact_id = Flapjack::Data::Rule.intersect(:id => rule_ids).
          associated_ids_for(:contact, :inversed => true)

        [rule_ids_by_contact_id, route_ids_by_rule_id]
      end

      private

      # would need to be "#{entity.name}:#{name}" to be compatible with v1, but
      # to support name changes it must be something invariant
      def create_ack_hash
        return unless self.ack_hash.nil? # :on => :create isn't working
        self.id = self.class.generate_id if self.id.nil?
        self.ack_hash = Digest.hexencode(Digest::SHA1.new.digest(self.id))[0..7].downcase
      end

      def no_longer_alerting
        self.routes.intersect(:is_alerting => true).each do |route|
          route.is_alerting = false
          route.save
        end

        unless self.alerting_media.empty?
          self.alerting_media.delete(*self.alerting_media)
        end
      end

      def scheduled_maintenances_at(t)
        start_range = Zermelo::Filters::IndexRange.new(nil, t, :by_score => true)
        end_range   = Zermelo::Filters::IndexRange.new(t, nil, :by_score => true)
        self.scheduled_maintenances.intersect(:start_time => start_range,
          :end_time => end_range)
      end

      def unscheduled_maintenances_at(t)
        start_range = Zermelo::Filters::IndexRange.new(nil, t, :by_score => true)
        end_range   = Zermelo::Filters::IndexRange.new(t, nil, :by_score => true)
        self.unscheduled_maintenances.intersect(:start_time => start_range,
          :end_time => end_range)
      end

    end

  end

end
