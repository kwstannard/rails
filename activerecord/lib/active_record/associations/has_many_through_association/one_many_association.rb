module ActiveRecord
  # = Active Record Has Many Through Association
  module Associations
    class HasManyThroughAssociation < HasManyAssociation #:nodoc:

      class OneManyAssociation < HasManyThroughAssociation
        def load_target
          if should_delegate?
            @target = through_association.target.send(reflection.source_reflection_name)
          elsif find_target?
            @target = merge_target_lists(find_target, target)
          end

          loaded!
          target
        end

      end
    end
  end
end
