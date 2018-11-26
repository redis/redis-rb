# Welcome

Thank you for your contribution. First off, fork and git clone please.

## Depended library installation

```
$ gem install bundler # if needed
$ bundle install --path=.bundle
```

## Redis bootation

```
$ make start          # booting standalone Redis
$ make start_cluster  # booting cluster mode Redis*6
$ make create_cluster # building cluster as master*3 and replica*3
```

## Running tests

```
$ bin/rake test                     # running all tests
$ bin/rake test test/bitpos_test.rb # running just specific test files
$ make test                         # same as "bin/rake test" for CI
```

## Stopping Redis

```
$ make stop         # stopping standalone Redis
$ make stop_cluster # stopping cluster mode Redis * 6
```
