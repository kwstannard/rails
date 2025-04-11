# frozen_string_literal: true

require "isolation/abstract_unit"
require "rack/test"

module Rails
  class Engine
    class FullyIsolatedTest < ActiveSupport::TestCase
      include ActiveSupport::Testing::Isolation

      setup :build_modular_app
      teardown :teardown_app

      test "engine can isolate if there is both an ApplicationRecord and a database configuration" do
        build_engine('admin')
        build_engine('client')
        require "#{app_path}/config/application"

        assert_equal(Client::Post.configurations.configs_for.first.database, 'client_development')
        assert_equal(Client::ApplicationRecord.configurations.configs_for.first.database, 'client_development')
        assert_equal(Admin::Post.configurations.configs_for.first.database, 'admin_development')
        assert_equal(Admin::ApplicationRecord.configurations.configs_for.first.database, 'admin_development')
        assert_nil(ActiveRecord::Base.configurations)
      end

      test "a useful error happens if there is database configuration but not ApplicationRecord" do
        build_broken_engine('client')

        assert_raises(ActiveRecord::ConfigurationError, match: /Engines with a configuration must have an ApplicationRecord/) {
          require "#{app_path}/config/application"
        }
      end

      test "engines automatically run database rake tasks appropriately" do
        build_engine('admin')
        build_engine('client')
        require "#{app_path}/config/application"
        Rails.application.load_tasks

        Rake::Task["db:prepare"].invoke

        Client::Post.create!
        Admin::Post.create!
        Admin::Post.create!

        assert_equal(Client::Post.count, 1)
        assert_equal(Admin::Post.count, 2)
      end

      private

        def build_engine(name)
          build_broken_engine(name)
          const = name.capitalize
          engine name do |plugin|
            plugin.write "app/models/#{name}/application_record.rb", <<~RUBY
              module #{const}
                class ApplicationRecord < ActiveRecord::Base
                  self.abstract_class = true
                end
              end
            RUBY
          end
        end

        def build_broken_engine(name)
          const = name.capitalize
          engine name do |plugin|
            plugin.write "app/models/#{name}/post.rb", <<~RUBY
              module #{const}
                class Post < ApplicationRecord
                end
              end
            RUBY

            plugin.write "db/migrate/1234_posts.rb", <<~RUBY
              class Posts < ActiveRecord::Migration[8.1].for(#{const}::Engine.instance)
                def change
                  create_table :posts
                end
              end
            RUBY

            plugin.write "config/database.yml", <<~YML
              development:
                adapter: sqlite3
                database: #{name}_development
            YML

            plugin.write "lib/#{name}.rb", <<~RUBY
              module #{const}
                class Engine < ::Rails::Engine
                  isolate_namespace #{const}
                end
              end
            RUBY

            plugin.write "config/routes.rb", <<~RUBY
              #{const}::Engine.routes.draw do
                root to: proc { [200, {}, []] }

                resources(:posts)
              end

              Rails.application.routes.draw do
                mount #{const}::Engine => "/#{name}"
              end
            RUBY
          end
        end

        def build_modular_app(options={})
          @prev_rails_app_class = Rails.app_class
          @prev_rails_application = Rails.application
          Rails.app_class = Rails.application = nil

          @prev_rails_env = ENV["RAILS_ENV"]
          ENV["RAILS_ENV"] = "development"

          FileUtils.rm_rf(app_path)
          FileUtils.cp_r(app_template_path + "/bin", app_path)
          FileUtils.mkdir(app_path + '/config')

          File.write("#{app_path}/config/application.rb", <<~EMPTY)
            require 'rails/all'
            class App < Rails::Application
              config.root = __dir__
            end
            App.initialize!
          EMPTY
        end
    end
  end
end
