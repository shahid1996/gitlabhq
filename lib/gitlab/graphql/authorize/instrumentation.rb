# frozen_string_literal: true

module Gitlab
  module Graphql
    module Authorize
      class Instrumentation
        # Replace the resolver for the field with one that will only return the
        # resolved object if the permissions check is successful.
        #
        # Collections are not supported. Apply permissions checks for those at the
        # database level instead, to avoid loading superfluous data from the DB
        def instrument(_type, field)
          field_definition = field.metadata[:type_class]
          return field unless field_definition.respond_to?(:required_permissions)
          return field if field_definition.required_permissions.empty?

          old_resolver = field.resolve_proc

          new_resolver = -> (obj, args, ctx) do
            resolved_obj = old_resolver.call(obj, args, ctx)
            checker = build_checker(ctx[:current_user], field_definition.required_permissions)

            if resolved_obj.respond_to?(:then)
              resolved_obj.then(&checker)
            else
              checker.call(resolved_obj)
            end
          end

          field.redefine do
            resolve(new_resolver)
          end
        end

        private

        def build_checker(current_user, abilities)
          lambda do |value|
            # Load the elements if they weren't loaded by BatchLoader yet
            value = value.sync if value.respond_to?(:sync)

            check = lambda do |object|
              abilities.all? do |ability|
                Ability.allowed?(current_user, ability, object)
              end
            end

            case value
            when Array
              value.select(&check)
            else
              value if check.call(value)
            end
          end
        end
      end
    end
  end
end
