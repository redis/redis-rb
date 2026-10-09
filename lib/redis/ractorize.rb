# frozen_string_literal: true

require "redis"

Redis::Client::ERROR_MAPPING.freeze
Redis::Cluster::Client::ERROR_MAPPING.freeze if defined?(Redis::Cluster::Client)
