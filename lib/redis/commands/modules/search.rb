# frozen_string_literal: true

require "redis/commands/modules/search/dialect"
require "redis/commands/modules/search/index_definition"
require "redis/commands/modules/search/field"
require "redis/commands/modules/search/schema"
require "redis/commands/modules/search/query"
require "redis/commands/modules/search/index"
require "redis/commands/modules/search/result"
require "redis/commands/modules/search/miscellaneous"
require "redis/commands/modules/search/hybrid"
require "redis/commands/modules/search/aggregation"

class Redis
  module Commands
    module Search
    end
  end
end
