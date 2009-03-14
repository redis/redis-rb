# redis-rb

A ruby client library for the redis key value storage system.

## Information about redis

Redis is a key value store with some interesting features:
1. It's fast.
2. Keys are strings but values can have types of "NONE", "STRING", "LIST",  or "SET".  List's can be atomically push'd, pop'd, lpush'd, lpop'd and indexed.  This allows you to store things like lists of comments under one key while retaining the ability to append comments without reading and putting back the whole list.

See [redis on code.google.com](http://code.google.com/p/redis/wiki/README) for more information.

## redis-rb dependencies

1. redis - rake redis:install will build the latest version from source.
2. dtach - rake dtach:install will build 0.8 from source.
3. svn - git is the new black, but we need it for the google codes.


## useful information

1. Use the tasks mentioned above (in redis-rb dependencies) to get your machine setup.
2. 
