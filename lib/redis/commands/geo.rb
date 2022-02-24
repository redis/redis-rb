# frozen_string_literal: true

class Redis
  module Commands
    module Geo
      # Adds the specified geospatial items (latitude, longitude, name) to the specified key
      #
      # @param [String] key
      # @param [Array] member arguemnts for member or members: longitude, latitude, name
      # @return [Integer] number of elements added to the sorted set
      def geoadd(key, *member)
        send_command([:geoadd, key, *member])
      end

      # Returns geohash string representing position for specified members of the specified key.
      #
      # @param [String] key
      # @param [String, Array<String>] member one member or array of members
      # @return [Array<String, nil>] returns array containg geohash string if member is present, nil otherwise
      def geohash(key, member)
        send_command([:geohash, key, member])
      end

      # Query a sorted set representing a geospatial index to fetch members matching a
      # given maximum distance from a point
      #
      # @param [Array] args key, longitude, latitude, radius, unit(m|km|ft|mi)
      # @param ['asc', 'desc'] sort sort returned items from the nearest to the farthest
      #   or the farthest to the nearest relative to the center
      # @param [Integer] count limit the results to the first N matching items
      # @param ['WITHDIST', 'WITHCOORD', 'WITHHASH'] options to return additional information
      # @return [Array<String>] may be changed with `options`
      def georadius(*args, **geoptions)
        geoarguments = _geoarguments(*args, **geoptions)

        send_command([:georadius, *geoarguments])
      end

      # Query a sorted set representing a geospatial index to fetch members matching a
      # given maximum distance from an already existing member
      #
      # @param [Array] args key, member, radius, unit(m|km|ft|mi)
      # @param ['asc', 'desc'] sort sort returned items from the nearest to the farthest or the farthest
      #   to the nearest relative to the center
      # @param [Integer] count limit the results to the first N matching items
      # @param ['WITHDIST', 'WITHCOORD', 'WITHHASH'] options to return additional information
      # @return [Array<String>] may be changed with `options`
      def georadiusbymember(*args, **geoptions)
        geoarguments = _geoarguments(*args, **geoptions)

        send_command([:georadiusbymember, *geoarguments])
      end

      # Query a sorted set representing a geospatial index to fetch members
      # within the borders of the area specified by a given shape
      # from a point or an already existing member
      #
      # @param [String] key
      # @params [String, Array<String>] from use the position of a existing <member> in the sorted set,
      #   or an array of longitude and latitude of a position
      # @params [Array<String>] by depending on the query's shape, it can be an array of [radius, unit]
      #   or an array of [width, height, unit(m|km|ft|mi)]
      # @param ['asc', 'desc'] sort sort returned items from the nearest to the farthest
      #   or the farthest to the nearest relative to the center
      # @param [Integer] count limit the results to the first N matching items
      # @param ['WITHDIST', 'WITHCOORD', 'WITHHASH'] options to return additional information
      # @return [Array<String>] may be changed with `options`
      def geosearch(key, from: nil, by: nil, **options)
        args = [key]
        if from.is_a? Array
          args << ["FROMLONLAT", from[0], from[1]]
        elsif from.is_a? String
          args << ["FROMMEMBER", from]
        else
          raise ArgumentError, ":from should be an Array with longitude and latitude or a String of an already existing member's name"
        end

        if by.size == 2
          args << ["BYRADIUS", by[0], by[1]]
        elsif area.size == 3
          args << ["BYBOX", by[0], by[1], by[2]]
        else
          raise ArgumentError, ":by should be an Array of [radius, unit] or [width, height, unit]"
        end

        geoarguments = _geoarguments(*args, **options)

        send_command([:geosearch, *geoarguments])
      end

      # Returns longitude and latitude of members of a geospatial index
      #
      # @param [String] key
      # @param [String, Array<String>] member one member or array of members
      # @return [Array<Array<String>, nil>] returns array of elements, where each
      #   element is either array of longitude and latitude or nil
      def geopos(key, member)
        send_command([:geopos, key, member])
      end

      # Returns the distance between two members of a geospatial index
      #
      # @param [String ]key
      # @param [Array<String>] members
      # @param ['m', 'km', 'mi', 'ft'] unit
      # @return [String, nil] returns distance in spefied unit if both members present, nil otherwise.
      def geodist(key, member1, member2, unit = 'm')
        send_command([:geodist, key, member1, member2, unit])
      end

      private

      def _geoarguments(*args, options: nil, sort: nil, count: nil)
        args.push sort if sort
        args.push 'count', count if count
        args.push options if options
        args
      end
    end
  end
end
