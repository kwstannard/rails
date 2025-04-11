# frozen_string_literal: true

class Hash
  def merge_leaves(other)
    if values.all? {|value| value.is_a? Hash }
      transform_values {|value| value.merge_leaves(other) }
    else
      merge(other)
    end
  end
end
