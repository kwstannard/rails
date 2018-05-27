# frozen_string_literal: true

require "rails/railtie/configuration"

module Rails
  class Engine
    class Configuration < ::Rails::Railtie::Configuration
      attr_reader :root
      attr_accessor :middleware
      attr_writer :eager_load_paths, :autoload_once_paths, :autoload_paths

      def initialize(root = nil)
        super()
        @root = root
        @generators = app_generators.dup
        @middleware = Rails::Configuration::MiddlewareStackProxy.new
      end

      # Holds generators configuration:
      #
      #   config.generators do |g|
      #     g.orm             :data_mapper, migration: true
      #     g.template_engine :haml
      #     g.test_framework  :rspec
      #   end
      #
      # If you want to disable color in console, do:
      #
      #   config.generators.colorize_logging = false
      #
      def generators
        @generators ||= Rails::Configuration::Generators.new
        yield(@generators) if block_given?
        @generators
      end

      def paths
        @paths ||= begin
          paths = Rails::Paths::Root.new(@root)

          paths.add "app",                 eager_load: true, glob: "{*,*/concerns}"
          paths.add "app/assets",          glob: "*"
          paths.add "app/controllers",     eager_load: true
          paths.add "app/channels",        eager_load: true, glob: "**/*_channel.rb"
          paths.add "app/helpers",         eager_load: true
          paths.add "app/models",          eager_load: true
          paths.add "app/mailers",         eager_load: true
          paths.add "app/views"

          paths.add "lib",                 load_path: true
          paths.add "lib/assets",          glob: "*"
          paths.add "lib/tasks",           glob: "**/*.rake"

          paths.add "config"
          paths.add "config/database",     with: "config/database.yml"
          paths.add "config/environments", glob: "#{Rails.env}.rb"
          paths.add "config/initializers", glob: "**/*.rb"
          paths.add "config/locales",      glob: "*.{rb,yml}"
          paths.add "config/routes.rb"

          paths.add "db"
          paths.add "db/migrate"
          paths.add "db/seeds.rb"

          paths.add "vendor",              load_path: true
          paths.add "vendor/assets",       glob: "*"

          paths
        end
      end

      def root=(value)
        @root = paths.path = Pathname.new(value).expand_path
      end

      def eager_load_paths
        @eager_load_paths ||= paths.eager_load
      end

      def autoload_once_paths
        @autoload_once_paths ||= paths.autoload_once
      end

      def autoload_paths
        @autoload_paths ||= paths.autoload_paths
      end

      # Loads and returns the entire raw configuration of database from
      # values stored in <tt>config/database.yml</tt>.
      def database_configuration
        path = paths["config/database"].existent.first
        yaml = Pathname.new(path) if path

        config = if yaml && yaml.exist?
          require "yaml"
          require "erb"
          loaded_yaml = YAML.load(ERB.new(yaml.read).result) || {}
          shared = loaded_yaml.delete("shared")
          if shared
            loaded_yaml.each do |_k, values|
              values.reverse_merge!(shared)
            end
          end
          Hash.new(shared).merge(loaded_yaml)
        elsif ENV["DATABASE_URL"]
          # Value from ENV['DATABASE_URL'] is set to default database connection
          # by Active Record.
          {}
        else
          raise "Could not load database configuration. No such file - #{paths["config/database"].instance_variable_get(:@paths)}"
        end

        config
      rescue Psych::SyntaxError => e
        raise "YAML syntax error occurred while parsing #{paths["config/database"].first}. " \
              "Please note that YAML must be consistently indented using spaces. Tabs are not allowed. " \
              "Error: #{e.message}"
      rescue => e
        raise e, "Cannot load `Rails.application.database_configuration`:\n#{e.message}", e.backtrace
      end
    end
  end
end
