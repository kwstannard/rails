module ActiveRecord
  # = \Migration \Context
  #
  # MigrationContext sets the context in which a migration is run.
  #
  # A migration context requires the path to the migrations is set
  # in the +migrations_paths+ parameter. Optionally a +schema_migration+
  # class can be provided. Multiple database applications will instantiate
  # a +SchemaMigration+ object per database. From the Rake tasks, \Rails will
  # handle this for you.
  class MigrationContext
    attr_reader :migrations_paths, :schema_migration, :internal_metadata, :connection_pool

    def initialize(connection_pool, migrations_paths, schema_migration = nil, internal_metadata = nil)
      @connection_pool = connection_pool
      @migrations_paths = migrations_paths
      @schema_migration = schema_migration || SchemaMigration.new(connection_pool)
      @internal_metadata = internal_metadata || InternalMetadata.new(connection_pool)
    end

    # Runs the migrations in the +migrations_path+.
    #
    # If +target_version+ is +nil+, +migrate+ will run +up+.
    #
    # If the +current_version+ and +target_version+ are both
    # 0 then an empty array will be returned and no migrations
    # will be run.
    #
    # If the +current_version+ in the schema is greater than
    # the +target_version+, then +down+ will be run.
    #
    # If none of the conditions are met, +up+ will be run with
    # the +target_version+.
    def migrate(target_version = nil, &block)
      case
      when target_version.nil?
        up(target_version, &block)
      when current_version == 0 && target_version == 0
        []
      when current_version > target_version
        down(target_version, &block)
      else
        up(target_version, &block)
      end
    end

    def rollback(steps = 1) # :nodoc:
      move(:down, steps)
    end

    def forward(steps = 1) # :nodoc:
      move(:up, steps)
    end

    def up(target_version = nil, &block) # :nodoc:
      selected_migrations = if block_given?
        migrations.select(&block)
      else
        migrations
      end

      connection_pool.with_connection do |connection|
        Migrator.new(connection, :up, selected_migrations, schema_migration, internal_metadata, target_version).migrate
      end
    end

    def down(target_version = nil, &block) # :nodoc:
      selected_migrations = if block_given?
        migrations.select(&block)
      else
        migrations
      end

      connection_pool.with_connection do |connection|
        Migrator.new(connection, :down, selected_migrations, schema_migration, internal_metadata, target_version).migrate
      end
    end

    def run(direction, target_version) # :nodoc:
      connection_pool.with_connection do |connection|
        Migrator.new(connection, direction, migrations, schema_migration, internal_metadata, target_version).run
      end
    end

    def open # :nodoc:
      connection_pool.with_connection do |connection|
        Migrator.new(connection, :up, migrations, schema_migration, internal_metadata)
      end
    end

    def get_all_versions # :nodoc:
      if schema_migration.table_exists?
        schema_migration.integer_versions
      else
        []
      end
    end

    def current_version # :nodoc:
      get_all_versions.max || 0
    rescue ActiveRecord::NoDatabaseError
    end

    def needs_migration? # :nodoc:
      pending_migration_versions.size > 0
    end

    def pending_migration_versions # :nodoc:
      migrations.collect(&:version) - get_all_versions
    end

    def migrations # :nodoc:
      migrations = migration_files.map do |file|
        version, name, scope = parse_migration_filename(file)
        raise IllegalMigrationNameError.new(file) unless version
        if validate_timestamp? && !valid_migration_timestamp?(version)
          raise InvalidMigrationTimestampError.new(version, name)
        end
        version = version.to_i
        name = name.camelize

        MigrationProxy.new(name, version, file, scope)
      end

      migrations.sort_by(&:version)
    end

    def migrations_status # :nodoc:
      db_list = schema_migration.normalized_versions

      file_list = migration_files.filter_map do |file|
        version, name, scope = parse_migration_filename(file)
        raise IllegalMigrationNameError.new(file) unless version
        if validate_timestamp? && !valid_migration_timestamp?(version)
          raise InvalidMigrationTimestampError.new(version, name)
        end
        version = schema_migration.normalize_migration_number(version)
        status = db_list.delete(version) ? "up" : "down"
        [status, version, (name + scope).humanize]
      end

      db_list.map! do |version|
        ["up", version, "********** NO FILE **********"]
      end

      (db_list + file_list).sort_by { |_, version, _| version.to_i }
    end

    def current_environment # :nodoc:
      ActiveRecord::ConnectionHandling::DEFAULT_ENV.call
    end

    def protected_environment? # :nodoc:
      ActiveRecord::Base.protected_environments.include?(last_stored_environment) if last_stored_environment
    end

    def last_stored_environment # :nodoc:
      internal_metadata = connection_pool.internal_metadata
      return nil unless internal_metadata.enabled?
      return nil if current_version == 0
      raise NoEnvironmentInSchemaError unless internal_metadata.table_exists?

      environment = internal_metadata[:environment]
      raise NoEnvironmentInSchemaError unless environment
      environment
    end

    private
      def migration_files
        paths = Array(migrations_paths)
        Dir[*paths.flat_map { |path| "#{path}/**/[0-9]*_*.rb" }]
      end

      def parse_migration_filename(filename)
        File.basename(filename).scan(Migration::MigrationFilenameRegexp).first
      end

      def validate_timestamp?
        ActiveRecord.timestamped_migrations && ActiveRecord.validate_migration_timestamps
      end

      def valid_migration_timestamp?(version)
        version.to_i < (Time.now.utc + 1.day).strftime("%Y%m%d%H%M%S").to_i
      end

      def move(direction, steps)
        connection_pool.with_connection do |connection|
          migrator = Migrator.new(connection, direction, migrations, schema_migration, internal_metadata)
          current_migration = migrator.current_migration
          migrations = migrator.migrations
        end

        if current_version != 0 && !current_migration
          raise UnknownMigrationVersionError.new(current_version)
        end

        start_index =
          if current_version == 0
            0
          else
            migrations.index(current_migration)
          end

        finish = migrations[start_index + steps]
        version = finish ? finish.version : 0
        public_send(direction, version)
      end
  end
end
