# frozen_string_literal: true

class Redis
  module Commands
    module Geo
      # Adds the specified geospatial items (latitude, longitude, name) to the specified key
      #
      # @param [String] key
      # @param [Array] member arguemnts for member or members: longitude, latitude, name
      # @param [Boolean] nx don't update already existing elements, always add new ones (since Redis 6.2)
      # @param [Boolean] xx only update elements that already exist, never add new ones (since Redis 6.2)
      # @param [Boolean] ch modify the return value to the number of changed elements (since Redis 6.2)
      # @return [Integer] number of elements added to the sorted set, or changed when `ch` is set
      def geoadd(key, *member, nx: false, xx: false, ch: false)
        raise ArgumentError, "can't supply both nx and xx" if nx && xx

        args = [:geoadd, key]
        args << "NX" if nx
        args << "XX" if xx
        args << "CH" if ch
        args.concat(member)
        send_command(args)
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
      # @param [Boolean] count_any return as soon as enough matches found (only with count, since Redis 6.2)
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
      # @param [Boolean] count_any return as soon as enough matches found (only with count, since Redis 6.2)
      # @param ['WITHDIST', 'WITHCOORD', 'WITHHASH'] options to return additional information
      # @return [Array<String>] may be changed with `options`
      def georadiusbymember(*args, **geoptions)
        geoarguments = _geoarguments(*args, **geoptions)

        send_command([:georadiusbymember, *geoarguments])
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

      # Return the members of a geospatial sorted set that are within the borders of the
      # area specified by a given shape, either a circle (BYRADIUS) or a rectangle (BYBOX),
      # starting from a center point given either by member (FROMMEMBER) or by longitude and
      # latitude (FROMLONLAT). Available since Redis 6.2.
      #
      # @example Search by radius from longitude/latitude
      #   redis.geosearch("Sicily", fromlonlat: [15, 37], byradius: [200, "km"], sort: "asc")
      #     # => ["Catania", "Palermo"]
      #
      # @example Search by box from an existing member, with extras
      #   redis.geosearch("Sicily", frommember: "Catania", bybox: [400, 400, "km"],
      #                   sort: "asc", withcoord: true, withdist: true)
      #     # => [["Catania", "0.0000", ["15.087...", "37.502..."]], ...]
      #
      # @param [String] key
      # @param [String] frommember use the position of the given existing member as the center
      # @param [Array<Numeric>] fromlonlat a [longitude, latitude] pair used as the center
      # @param [Array] byradius a [radius, unit] pair where unit is one of 'm', 'km', 'ft', 'mi'
      # @param [Array] bybox a [width, height, unit] triple where unit is one of 'm', 'km', 'ft', 'mi'
      # @param ['asc', 'desc'] sort sort returned items from the nearest to the farthest, or vice versa
      # @param [Integer] count limit the results to the first N matching items
      # @param [Boolean] count_any return as soon as enough matches are found (only with count)
      # @param [Boolean] withcoord also return the longitude and latitude of matching items
      # @param [Boolean] withdist also return the distance from the center point
      # @param [Boolean] withhash also return the raw geohash-encoded sorted set score of the item
      # @return [Array<String>] may be changed with WITH* flags
      def geosearch(key, frommember: nil, fromlonlat: nil, byradius: nil, bybox: nil,
                    sort: nil, count: nil, count_any: false,
                    withcoord: false, withdist: false, withhash: false)
        args = [key]
        args << "FROMMEMBER" << frommember if frommember
        args << "FROMLONLAT" << fromlonlat[0] << fromlonlat[1] if fromlonlat
        args << "BYRADIUS" << byradius[0] << byradius[1] if byradius
        args << "BYBOX" << bybox[0] << bybox[1] << bybox[2] if bybox

        options = []
        options << "WITHCOORD" if withcoord
        options << "WITHDIST" if withdist
        options << "WITHHASH" if withhash

        geoarguments = _geoarguments(*args, sort: sort, count: count, count_any: count_any, options: options)

        send_command([:geosearch, *geoarguments])
      end

      # Like GEOSEARCH, but stores the result in a destination key. By default the destination
      # is populated with the matching members and their geospatial scores; when STOREDIST is
      # set, the members are stored with their distance from the center point as the score.
      # Available since Redis 6.2.
      #
      # @example Store the three nearest members
      #   redis.geosearchstore("nearest", "Sicily",
      #                        fromlonlat: [15, 37], bybox: [400, 400, "km"], sort: "asc", count: 3)
      #     # => 3
      #
      # @example Store distances as scores
      #   redis.geosearchstore("distances", "Sicily",
      #                        fromlonlat: [15, 37], bybox: [400, 400, "km"], storedist: true)
      #     # => 3
      #
      # @param [String] destination key to store the result in
      # @param [String] source geospatial sorted set to search
      # @param [String] frommember use the position of the given existing member as the center
      # @param [Array<Numeric>] fromlonlat a [longitude, latitude] pair used as the center
      # @param [Array] byradius a [radius, unit] pair where unit is one of 'm', 'km', 'ft', 'mi'
      # @param [Array] bybox a [width, height, unit] triple where unit is one of 'm', 'km', 'ft', 'mi'
      # @param ['asc', 'desc'] sort sort returned items from the nearest to the farthest, or vice versa
      # @param [Integer] count limit the results to the first N matching items
      # @param [Boolean] count_any return as soon as enough matches are found (only with count)
      # @param [Boolean] storedist store the distance from the center point as the score
      # @return [Integer] number of elements stored in the destination key
      def geosearchstore(destination, source, frommember: nil, fromlonlat: nil, byradius: nil, bybox: nil,
                         sort: nil, count: nil, count_any: false, storedist: false)
        args = [destination, source]
        args << "FROMMEMBER" << frommember if frommember
        args << "FROMLONLAT" << fromlonlat[0] << fromlonlat[1] if fromlonlat
        args << "BYRADIUS" << byradius[0] << byradius[1] if byradius
        args << "BYBOX" << bybox[0] << bybox[1] << bybox[2] if bybox

        options = []
        options << "STOREDIST" if storedist

        geoarguments = _geoarguments(*args, sort: sort, count: count, count_any: count_any, options: options)

        send_command([:geosearchstore, *geoarguments])
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

      def _geoarguments(*args, options: nil, sort: nil, count: nil, count_any: false)
        args << sort if sort
        if count
          args << 'COUNT' << Integer(count)
          args << 'ANY' if count_any
        end
        args.concat(Array(options))
        args
      end
    end
  end
end
