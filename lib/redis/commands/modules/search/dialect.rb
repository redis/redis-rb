# frozen_string_literal: true

class Redis
  module Commands
    module Search
      # Default query dialect used for FT.SEARCH and FT.AGGREGATE
      # +DEFAULT_DIALECT+. Dialect 2 is the recommended baseline: it supports modern query syntax
      # such as vector (KNN) and geoshape predicates, whereas the server's built-in default is
      # dialect 1. Override per query via {Query#dialect} / {AggregateRequest#dialect} or the
      # +dialect:+ option to +ft_search+/+ft_aggregate+.
      DEFAULT_DIALECT = 2
    end
  end
end
