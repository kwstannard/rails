# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    class PoolManager # :nodoc:
      def initialize
        @role_to_shard_mapping = Hash.new { |h, k| h[k] = {} }
      end

      def shard_names
        @role_to_shard_mapping.values.flat_map { |shard_map| shard_map.keys }.uniq
      end

      def role_names
        @role_to_shard_mapping.keys
      end

      def pool_configs(role = nil)
        if role && role != :all
          @role_to_shard_mapping[role].values
        else
          @role_to_shard_mapping.flat_map { |_, shard_map| shard_map.values }
        end
      end

      def each_pool_config(role = nil, &block)
        if role && role != :all
          @role_to_shard_mapping[role].each_value(&block)
        else
          @role_to_shard_mapping.each_value do |shard_map|
            shard_map.each_value(&block)
          end
        end
      end

      def remove_role(role)
        @role_to_shard_mapping.delete(role)
      end

      def remove_pool_config(role, shard)
        @role_to_shard_mapping[role].delete(shard)
      end

      def get_pool_config(role, shard)
        @role_to_shard_mapping[role][shard]
      end

      def update_pool_config(connection_name, role, shard, db_config)
        pool_config = ConnectionAdapters::PoolConfig.new(connection_name, db_config, role, shard)
        existing_pool_config = get_pool_config(role, shard)
        if existing_pool_config && existing_pool_config.db_config == db_config && connection_name.primary_class? 
          existing_pool_config.connection_descriptor = connection_name
        end
        existing_pool_config
      end

      def clobber_pool_config(connection_name, role, shard, db_config)
        pool_config = remove_pool_config(role, shard)

        if pool_config
          pool_config.disconnect!
          pool_config.db_config
        end
        pool_manager.set_pool_config(role, shard, pool_config)

        payload = {
          connection_name: pool_config.connection_descriptor.name,
          role: role,
          shard: shard,
          config: db_config.configuration_hash
        }

        ActiveSupport::Notifications.instrumenter.instrument("!connection.active_record", payload) do
          pool_config.pool
        end
      end

      def set_pool_config(role, shard, pool_config)
        if pool_config
          @role_to_shard_mapping[role][shard] = pool_config
        else
          raise ArgumentError, "The `pool_config` for the :#{role} role and :#{shard} shard was `nil`. Please check your configuration. If you want your writing role to be something other than `:writing` set `config.active_record.writing_role` in your application configuration. The same setting should be applied for the `reading_role` if applicable."
        end
      end
    end
  end
end
