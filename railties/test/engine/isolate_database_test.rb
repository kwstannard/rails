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

        assert_equal(Client::Post.count, 0)
        assert_equal(Admin::Post.count, 0)
      end

      # test "engine lazily loads routes when invoking url helpers" do
      #   require "#{app_path}/config/environment"

      #   assert_not_operator(:root_path, :in?, engine_url_helpers.methods)
      #   assert_equal("/plugin/", engine_url_helpers.root_path)
      # end

      # test "app lazily loads routes when checking respond_to?" do
      #   require "#{app_path}/config/environment"

      #   assert_not_operator(:root_path, :in?, app_url_helpers.methods)
      #   assert_operator(app_url_helpers, :respond_to?, :root_path)
      # end

      # test "engine lazily loads routes when checking respond_to?" do
      #   require "#{app_path}/config/environment"

      #   assert_not_operator(:root_path, :in?, engine_url_helpers.methods)
      #   assert_operator(engine_url_helpers, :respond_to?, :root_path)
      # end

      # test "app lazily loads routes when making a request" do
      #   require "#{app_path}/config/environment"

      #   @app = Rails.application

      #   assert_not_operator(:root_path, :in?, app_url_helpers.methods)
      #   response = get("/")
      #   assert_equal(200, response.first)
      # end

      # test "engine lazily loads routes when making a request" do
      #   require "#{app_path}/config/environment"

      #   @app = Rails.application

      #   assert_not_operator(:root_path, :in?, engine_url_helpers.methods)
      #   response = get("/plugin/")
      #   assert_equal(200, response.first)
      # end

      # test "app lazily loads routes when url_for is used" do
      #   require "#{app_path}/config/environment"

      #   @app = Rails.application

      #   assert_not_operator(:products_path, :in?, app_url_helpers.methods)
      #   assert_equal "/products", app_url_helpers.url_for(
      #     controller: :products, action: :index, only_path: true,
      #   )
      #   assert_operator(:products_path, :in?, app_url_helpers.methods)
      # end

      # test "engine lazily loads routes when url_for is used" do
      #   require "#{app_path}/config/environment"

      #   @app = Rails.application

      #   assert_not_operator(:plugin_posts_path, :in?, engine_url_helpers.methods)
      #   assert_equal "/plugin/posts", engine_url_helpers.url_for(
      #     controller: :posts, action: :index, only_path: true,
      #   )
      #   assert_not_operator(:plugin_posts_path, :in?, engine_url_helpers.methods)
      # end

      # test "railties can access lazy routes" do
      #   app_file("config/application.rb", <<~RUBY, "a+")

      #     class MyRailtie < ::Rails::Railtie
      #       initializer :some_railtie_init do |app|
      #         app.routes
      #       end
      #     end
      #   RUBY

      #   require "#{app_path}/config/environment"

      #   assert_operator(Rails.application.routes, :is_a?, Engine::LazyRouteSet)
      # end

      # test "reloads routes when recognize_path is called" do
      #   require "#{app_path}/config/environment"

      #   assert_equal(
      #     { controller: "rails/engine/lazy_route_set_test/users", action: "index" },
      #     Rails.application.routes.recognize_path("/users")
      #   )
      # end

      # test "reloads routes when recognize_path_with_request is called" do
      #   require "#{app_path}/config/environment"

      #   path = "/users"
      #   req = ActionDispatch::Request.new(::Rack::MockRequest.env_for(path))

      #   assert_equal(
      #     { controller: "rails/engine/lazy_route_set_test/users", action: "index" },
      #     Rails.application.routes.recognize_path_with_request(req, path, {})
      #   )
      # end

      private
      #   def build_app
      #     super

      #     app_file "app/models/user.rb", <<~RUBY
      #       class User < ActiveRecord::Base
      #       end
      #     RUBY

      #     app_file "config/routes.rb", <<~RUBY
      #       Rails.application.routes.draw do
      #         root to: proc { [200, {}, []] }

      #         resources :products
      #         resources :users, module: "rails/engine/lazy_route_set_test"

      #         mount Plugin::Engine, at: "/plugin"
      #       end
      #     RUBY

      #     build_engine
      #   end

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
    end
  end
end

      #   def app_url_helpers
      #     Rails.application.routes.url_helpers
      #   end

      #   def engine_url_helpers
      #     Plugin::Engine.routes.url_helpers
      #   end
    # end
  # end
# end
