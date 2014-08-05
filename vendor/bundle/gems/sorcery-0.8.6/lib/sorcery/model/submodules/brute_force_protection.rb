module Sorcery
  module Model
    module Submodules
      # This module helps protect user accounts by locking them down after too many failed attemps
      # to login were detected.
      # This is the model part of the submodule which provides configuration options and methods
      # for locking and unlocking the user.
      module BruteForceProtection
        def self.included(base)
          base.sorcery_config.class_eval do
            attr_accessor :failed_logins_count_attribute_name,        # failed logins attribute name.
                          :lock_expires_at_attribute_name,            # this field indicates whether user
                                                                      # is banned and when it will be active again.
                          :consecutive_login_retries_amount_limit,    # how many failed logins allowed.
                          :login_lock_time_period,                    # how long the user should be banned.
                                                                      # in seconds. 0 for permanent.

                          :unlock_token_attribute_name,               # Unlock token attribute name
                          :unlock_token_email_method_name,            # Mailer method name
                          :unlock_token_mailer_disabled,              # When true, dont send unlock token via email
                          :unlock_token_mailer                        # Mailer class
          end

          base.sorcery_config.instance_eval do
            @defaults.merge!(:@failed_logins_count_attribute_name              => :failed_logins_count,
                             :@lock_expires_at_attribute_name                  => :lock_expires_at,
                             :@consecutive_login_retries_amount_limit          => 50,
                             :@login_lock_time_period                          => 60 * 60,

                             :@unlock_token_attribute_name                     => :unlock_token,
                             :@unlock_token_email_method_name                  => :send_unlock_token_email,
                             :@unlock_token_mailer_disabled                    => false,
                             :@unlock_token_mailer                             => nil)
            reset!
          end

          base.sorcery_config.before_authenticate << :prevent_locked_user_login
          base.sorcery_config.after_config << :define_brute_force_protection_mongoid_fields if defined?(Mongoid) and base.ancestors.include?(Mongoid::Document)
          if defined?(MongoMapper) and base.ancestors.include?(MongoMapper::Document)
            base.sorcery_config.after_config << :define_brute_force_protection_mongo_mapper_fields
          end
          if defined?(DataMapper) and base.ancestors.include?(DataMapper::Resource)
            base.sorcery_config.after_config << :define_brute_force_protection_datamapper_fields
          end
          base.extend(ClassMethods)
          base.send(:include, InstanceMethods)
        end

        module ClassMethods
          def load_from_unlock_token(token)
            return nil if token.blank?
            user = find_by_sorcery_token(sorcery_config.unlock_token_attribute_name,token)
            user
          end

          protected

          def define_brute_force_protection_mongoid_fields
            field sorcery_config.failed_logins_count_attribute_name,  :type => Integer, :default => 0
            field sorcery_config.lock_expires_at_attribute_name,      :type => Time
            field sorcery_config.unlock_token_attribute_name,         :type => String
          end

          def define_brute_force_protection_mongo_mapper_fields
            key sorcery_config.failed_logins_count_attribute_name, Integer, :default => 0
            key sorcery_config.lock_expires_at_attribute_name, Time
            key sorcery_config.unlock_token_attribute_name, String
          end

          def define_brute_force_protection_datamapper_fields
            property sorcery_config.failed_logins_count_attribute_name, Integer, :default => 0
            property sorcery_config.lock_expires_at_attribute_name,     Time
            property sorcery_config.unlock_token_attribute_name,        String
            [sorcery_config.lock_expires_at_attribute_name].each do |sym|
              alias_method "orig_#{sym}", sym
              define_method(sym) do
                t = send("orig_#{sym}")
                t && Time.new(t.year, t.month, t.day, t.hour, t.min, t.sec, 0)
              end
            end
          end
        end

        module InstanceMethods
          # Called by the controller to increment the failed logins counter.
          # Calls 'lock!' if login retries limit was reached.
          def register_failed_login!
            config = sorcery_config
            return if !unlocked?
            self.increment(config.failed_logins_count_attribute_name)
            self.update_many_attributes(config.failed_logins_count_attribute_name => self.send(config.failed_logins_count_attribute_name))
            self.lock! if self.send(config.failed_logins_count_attribute_name) >= config.consecutive_login_retries_amount_limit
          end

          # /!\
          # Moved out of protected for use like activate! in controller
          # /!\
          def unlock!
            config = sorcery_config
            attributes = {config.lock_expires_at_attribute_name => nil,
                          config.failed_logins_count_attribute_name => 0,
                          config.unlock_token_attribute_name => nil}
            self.update_many_attributes(attributes)
          end

          protected

          def lock!
            config = sorcery_config
            attributes = {config.lock_expires_at_attribute_name => Time.now.in_time_zone + config.login_lock_time_period,
                          config.unlock_token_attribute_name => TemporaryToken.generate_random_token}
            self.update_many_attributes(attributes)

            unless config.unlock_token_mailer_disabled || config.unlock_token_mailer.nil?
              send_unlock_token_email!
            end
          end

          def unlocked?
            config = sorcery_config
            self.send(config.lock_expires_at_attribute_name).nil?
          end

          def send_unlock_token_email!
            generic_send_email(:unlock_token_email_method_name, :unlock_token_mailer) unless sorcery_config.unlock_token_email_method_name.nil?
          end

          # Prevents a locked user from logging in, and unlocks users that expired their lock time.
          # Runs as a hook before authenticate.
          def prevent_locked_user_login
            config = sorcery_config
            if !self.unlocked? && config.login_lock_time_period != 0
              self.unlock! if self.send(config.lock_expires_at_attribute_name) <= Time.now.in_time_zone
            end
            unlocked?
          end
        end
      end
    end
  end
end
