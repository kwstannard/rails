module ActiveRecord
  class Migrator # :nodoc:
    class << self
      attr_accessor :migrations_paths

      # For cases where a table doesn't exist like loading from schema cache
      def current_version
        connection_pool = ActiveRecord::Tasks::DatabaseTasks.migration_connection_pool
        schema_migration = SchemaMigration.new(connection_pool)
        internal_metadata = InternalMetadata.new(connection_pool)

        MigrationContext.new(migrations_paths, schema_migration, internal_metadata).current_version
      end
    end

    self.migrations_paths = ["db/migrate"]

    def initialize(connection, direction, migrations, schema_migration, internal_metadata, target_version = nil)
      @connection        = connection
      @direction         = direction
      @target_version    = target_version
      @migrated_versions = nil
      @migrations        = migrations
      @schema_migration  = schema_migration
      @internal_metadata = internal_metadata

      validate(@migrations)

      @schema_migration.create_table
      @internal_metadata.create_table
    end

    def current_version
      migrated.max || 0
    end

    def current_migration
      migrations.detect { |m| m.version == current_version }
    end
    alias :current :current_migration

    def run
      if use_advisory_lock?
        with_advisory_lock { run_without_lock }
      else
        run_without_lock
      end
    end

    def migrate
      if use_advisory_lock?
        with_advisory_lock { migrate_without_lock }
      else
        migrate_without_lock
      end
    end

    def runnable
      runnable = migrations[start..finish]
      if up?
        runnable.reject { |m| ran?(m) }
      else
        # skip the last migration if we're headed down, but not ALL the way down
        runnable.pop if target
        runnable.find_all { |m| ran?(m) }
      end
    end

    def migrations
      down? ? @migrations.reverse : @migrations.sort_by(&:version)
    end

    def pending_migrations
      already_migrated = migrated
      migrations.reject { |m| already_migrated.include?(m.version) }
    end

    def migrated
      @migrated_versions || load_migrated
    end

    def load_migrated
      @migrated_versions = Set.new(@schema_migration.integer_versions)
    end

    private
      # Used for running a specific migration.
      def run_without_lock
        migration = migrations.detect { |m| m.version == @target_version }
        raise UnknownMigrationVersionError.new(@target_version) if migration.nil?

        record_environment
        execute_migration_in_transaction(migration)
      end

      # Used for running multiple migrations up to or down to a certain value.
      def migrate_without_lock
        if invalid_target?
          raise UnknownMigrationVersionError.new(@target_version)
        end

        record_environment
        runnable.each(&method(:execute_migration_in_transaction))
      end

      # Stores the current environment in the database.
      def record_environment
        return if down?

        @internal_metadata[:environment] = @connection.pool.db_config.env_name
      end

      def ran?(migration)
        migrated.include?(migration.version.to_i)
      end

      # Return true if a valid version is not provided.
      def invalid_target?
        @target_version && @target_version != 0 && !target
      end

      def execute_migration_in_transaction(migration)
        return if down? && !migrated.include?(migration.version.to_i)
        return if up?   &&  migrated.include?(migration.version.to_i)

        Base.logger.info "Migrating to #{migration.name} (#{migration.version})" if Base.logger

        ddl_transaction(migration) do
          migration.migrate(@direction)
          record_version_state_after_migrating(migration.version)
        end
      rescue => e
        msg = +"An error has occurred, "
        msg << "this and " if use_transaction?(migration)
        msg << "all later migrations canceled:\n\n#{e}"
        raise StandardError, msg, e.backtrace
      end

      def target
        migrations.detect { |m| m.version == @target_version }
      end

      def finish
        migrations.index(target) || migrations.size - 1
      end

      def start
        up? ? 0 : (migrations.index(current) || 0)
      end

      def validate(migrations)
        name, = migrations.group_by(&:name).find { |_, v| v.length > 1 }
        raise DuplicateMigrationNameError.new(name) if name

        version, = migrations.group_by(&:version).find { |_, v| v.length > 1 }
        raise DuplicateMigrationVersionError.new(version) if version
      end

      def record_version_state_after_migrating(version)
        if down?
          migrated.delete(version)
          @schema_migration.delete_version(version.to_s)
        else
          migrated << version
          @schema_migration.create_version(version.to_s)
        end
      end

      def up?
        @direction == :up
      end

      def down?
        @direction == :down
      end

      # Wrap the migration in a transaction only if supported by the adapter.
      def ddl_transaction(migration, &block)
        if use_transaction?(migration)
          @connection.transaction(&block)
        else
          yield
        end
      end

      def use_transaction?(migration)
        !migration.disable_ddl_transaction && @connection.supports_ddl_transactions?
      end

      def use_advisory_lock?
        @connection.advisory_locks_enabled?
      end

      def with_advisory_lock
        lock_id = generate_migrator_advisory_lock_id

        got_lock = @connection.get_advisory_lock(lock_id)
        raise ConcurrentMigrationError unless got_lock
        load_migrated # reload schema_migrations to be sure it wasn't changed by another process before we got the lock
        yield
      ensure
        if got_lock && !@connection.release_advisory_lock(lock_id)
          raise ConcurrentMigrationError.new(
            ConcurrentMigrationError::RELEASE_LOCK_FAILED_MESSAGE
          )
        end
      end

      MIGRATOR_SALT = 2053462845
      def generate_migrator_advisory_lock_id
        db_name_hash = Zlib.crc32(@connection.current_database)
        MIGRATOR_SALT * db_name_hash
      end
  end
end
