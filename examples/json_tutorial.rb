# frozen_string_literal: true

# EXAMPLE: json_tutorial
# This example demonstrates Redis JSON operations including:
# - JSON.SET and JSON.GET with JSONPath
# - JSON.TYPE for checking data types
# - String operations (STRLEN, STRAPPEND)
# - Numeric operations (NUMINCRBY)
# - Array operations (ARRAPPEND, ARRINSERT, ARRTRIM, ARRPOP, DEL)
# - Object operations (OBJLEN, OBJKEYS)
# - Complex nested JSON documents
# - JSONPath queries and filters

require 'redis'
require 'json'

# Connect to Redis on port 6400
redis = Redis.new(host: 'localhost', port: 6400)

# Clear any keys before using them
redis.del('bike', 'bike:1', 'crashes', 'newbike', 'riders', 'bikes:inventory')

# STEP_START set_get
res1 = redis.json_set('bike', '$', 'Hyperion')
puts res1 # => OK

res2 = redis.json_get('bike', '$')
puts res2.inspect  # => ["Hyperion"]

res3 = redis.json_type('bike', '$')
puts res3.inspect  # => ["string"]
# STEP_END

# STEP_START str
res4 = redis.json_strlen('bike', '$')
puts res4.inspect  # => [8]

res5 = redis.json_strappend('bike', '$', ' (Enduro bikes)')
puts res5.inspect  # => [23]

res6 = redis.json_get('bike', '$')
puts res6.inspect  # => ["Hyperion (Enduro bikes)"]
# STEP_END

# STEP_START num
res7 = redis.json_set('crashes', '$', 0)
puts res7 # => OK

res8 = redis.json_numincrby('crashes', '$', 1)
puts res8.inspect  # => [1]

res9 = redis.json_numincrby('crashes', '$', 1.5)
puts res9.inspect  # => [2.5]

res10 = redis.json_numincrby('crashes', '$', -0.75)
puts res10.inspect # => [1.75]
# STEP_END

# STEP_START arr
res11 = redis.json_set('newbike', '$', ['Deimos', { crashes: 0 }, nil])
puts res11 # => OK

res12 = redis.json_get('newbike', '$')
puts res12.inspect  # => [["Deimos", {"crashes"=>0}, nil]]

res13 = redis.json_get('newbike', '$[1].crashes')
puts res13.inspect  # => [0]

res14 = redis.json_del('newbike', '$[-1]')
puts res14 # => 1

res15 = redis.json_get('newbike', '$')
puts res15.inspect # => [["Deimos", {"crashes"=>0}]]
# STEP_END

# STEP_START arr2
res16 = redis.json_set('riders', '$', [])
puts res16 # => OK

res17 = redis.json_arrappend('riders', '$', 'Norem')
puts res17.inspect  # => [1]

res18 = redis.json_get('riders', '$')
puts res18.inspect  # => [["Norem"]]

res19 = redis.json_arrinsert('riders', '$', 1, 'Prickett', 'Royce', 'Castilla')
puts res19.inspect  # => [4]

res20 = redis.json_get('riders', '$')
puts res20.inspect  # => [["Norem", "Prickett", "Royce", "Castilla"]]

res21 = redis.json_arrtrim('riders', '$', 1, 1)
puts res21.inspect  # => [1]

res22 = redis.json_get('riders', '$')
puts res22.inspect  # => [["Prickett"]]

res23 = redis.json_arrpop('riders', '$')
puts res23.inspect  # => ["Prickett"]

res24 = redis.json_arrpop('riders', '$')
puts res24.inspect  # => [nil]
# STEP_END

# STEP_START obj
res25 = redis.json_set('bike:1', '$', {
                         model: 'Deimos',
                         brand: 'Ergonom',
                         price: 4972
                       })
puts res25 # => OK

res26 = redis.json_objlen('bike:1', '$')
puts res26.inspect  # => [3]

res27 = redis.json_objkeys('bike:1', '$')
puts res27.inspect  # => [["model", "brand", "price"]]
# STEP_END

# STEP_START set_bikes
inventory_json = {
  inventory: {
    mountain_bikes: [
      {
        id: 'bike:1',
        model: 'Phoebe',
        description: "This is a mid-travel trail slayer that is a fantastic daily driver or one bike quiver. The Shimano Claris 8-speed groupset gives plenty of gear range to tackle hills and there's room for mudguards and a rack too.  This is the bike for the rider who wants trail manners with low fuss ownership.",
        price: 1920,
        specs: { material: 'carbon', weight: 13.1 },
        colors: ['black', 'silver']
      },
      {
        id: 'bike:2',
        model: 'Quaoar',
        description: "Redesigned for the 2020 model year, this bike impressed our testers and is the best all-around trail bike we've ever tested. The Shimano gear system effectively does away with an external cassette, so is super low maintenance in terms of wear and tear. All in all it's an impressive package for the price, making it very competitive.",
        price: 2072,
        specs: { material: 'aluminium', weight: 7.9 },
        colors: ['black', 'white']
      },
      {
        id: 'bike:3',
        model: 'Weywot',
        description: "This bike gives kids aged six years and older a durable and uberlight mountain bike for their first experience on tracks and easy cruising through forests and fields. A set of powerful Shimano hydraulic disc brakes provide ample stopping ability. If you're after a budget option, this is one of the best bikes you could get.",
        price: 3264,
        specs: { material: 'alloy', weight: 13.8 }
      }
    ],
    commuter_bikes: [
      {
        id: 'bike:4',
        model: 'Salacia',
        description: "This bike is a great option for anyone who just wants a bike to get about on With a slick-shifting Claris gears from Shimano's, this is a bike which doesn't break the bank and delivers craved performance.  It's for the rider who wants both efficiency and capability.",
        price: 1475,
        specs: { material: 'aluminium', weight: 16.6 },
        colors: ['black', 'silver']
      },
      {
        id: 'bike:5',
        model: 'Mimas',
        description: "A real joy to ride, this bike got very high scores in last years Bike of the year report. The carefully crafted 50-34 tooth chainset and 11-32 tooth cassette give an easy-on-the-legs bottom gear for climbing, and the high-quality Vittoria Zaffiro tires give balance and grip.It includes a low-step frame , our memory foam seat, bump-resistant shocks and conveniently placed thumb throttle. Put it all together and you get a bike that helps redefine what can be done for this price.",
        price: 3941,
        specs: { material: 'alloy', weight: 11.6 }
      }
    ]
  }
}

res28 = redis.json_set('bikes:inventory', '$', inventory_json)
puts res28 # => OK
# STEP_END

# STEP_START get_bikes
res29 = redis.json_get('bikes:inventory', '$.inventory.*')
puts res29.inspect
# => [[{"id"=>"bike:1", "model"=>"Phoebe", ...
# STEP_END

# STEP_START get_mtnbikes
res30 = redis.json_get('bikes:inventory', '$.inventory.mountain_bikes[*].model')
puts res30.inspect  # => ["Phoebe", "Quaoar", "Weywot"]

res31 = redis.json_get('bikes:inventory', '$.inventory["mountain_bikes"][*].model')
puts res31.inspect  # => ["Phoebe", "Quaoar", "Weywot"]

res32 = redis.json_get('bikes:inventory', '$..mountain_bikes[*].model')
puts res32.inspect  # => ["Phoebe", "Quaoar", "Weywot"]
# STEP_END

# STEP_START get_models
res33 = redis.json_get('bikes:inventory', '$..model')
puts res33.inspect # => ["Phoebe", "Quaoar", "Weywot", "Salacia", "Mimas"]
# STEP_END

# STEP_START get2mtnbikes
res34 = redis.json_get('bikes:inventory', '$..mountain_bikes[0:2].model')
puts res34.inspect # => ["Phoebe", "Quaoar"]
# STEP_END

# STEP_START filter1
res35 = redis.json_get('bikes:inventory', '$..mountain_bikes[?(@.price < 3000 && @.specs.weight < 10)]')
puts res35.inspect
# => [{"id"=>"bike:2", "model"=>"Quaoar", ...
# STEP_END

# STEP_START filter2
res36 = redis.json_get('bikes:inventory', '$..[?(@.specs.material == "alloy")].model')
puts res36.inspect # => ["Weywot", "Mimas"]
# STEP_END

# STEP_START filter3
res37 = redis.json_get('bikes:inventory', '$..[?(@.specs.material =~ "(?i)al")].model')
puts res37.inspect # => ["Quaoar", "Weywot", "Salacia", "Mimas"]
# STEP_END

# STEP_START filter4
redis.json_set('bikes:inventory', '$.inventory.mountain_bikes[0].regex_pat', '(?i)al')
redis.json_set('bikes:inventory', '$.inventory.mountain_bikes[1].regex_pat', '(?i)al')
redis.json_set('bikes:inventory', '$.inventory.mountain_bikes[2].regex_pat', '(?i)al')

res38 = redis.json_get('bikes:inventory', '$.inventory.mountain_bikes[?(@.specs.material =~ @.regex_pat)].model')
puts res38.inspect # => ["Quaoar", "Weywot"]
# STEP_END

# STEP_START update_bikes
res39 = redis.json_get('bikes:inventory', '$..price')
puts res39.inspect  # => [1920, 2072, 3264, 1475, 3941]

res40 = redis.json_numincrby('bikes:inventory', '$..price', -100)
puts res40.inspect  # => [1820, 1972, 3164, 1375, 3841]

res41 = redis.json_numincrby('bikes:inventory', '$..price', 100)
puts res41.inspect  # => [1920, 2072, 3264, 1475, 3941]
# STEP_END

# STEP_START update_filters1
redis.json_set('bikes:inventory', '$.inventory.*[?(@.price<2000)].price', 1500)
res42 = redis.json_get('bikes:inventory', '$..price')
puts res42.inspect # => [1500, 2072, 3264, 1500, 3941]
# STEP_END

# STEP_START update_filters2
res43 = redis.json_arrappend('bikes:inventory', '$.inventory.*[?(@.price<2000)].colors', 'pink')
puts res43.inspect  # => [3, 3]

res44 = redis.json_get('bikes:inventory', '$..[*].colors')
puts res44.inspect  # => [["black", "silver", "pink"], ["black", "white"], ["black", "silver", "pink"]]
# STEP_END

redis.close
puts "\nJSON tutorial completed successfully!"
