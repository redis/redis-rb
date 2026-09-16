#include <ruby.h>
#include <ruby/encoding.h>
#include <inttypes.h>
#include "xxhash.h"

/*
 * Computes the same digest as the Redis server's DIGEST command: XXH3_64bits (plain,
 * unseeded) formatted as 16 lowercase hex characters via "%016" PRIx64 — matching
 * stringDigest() in the server's src/t_string.c exactly, so results are byte-identical
 * for byte-identical input.
 */
static VALUE rb_xxh3_hexdigest(VALUE self, VALUE str) {
    str = rb_str_to_str(str);

    const char *ptr = RSTRING_PTR(str);
    long len = RSTRING_LEN(str);
    XXH64_hash_t hash = XXH3_64bits(ptr, (size_t)len);

    char buf[17];
    snprintf(buf, sizeof(buf), "%016" PRIx64, (uint64_t)hash);

    return rb_usascii_str_new(buf, 16);
}

void Init_xxh3_ext(void) {
    /* Redis is a Class throughout redis-rb (lib/redis.rb), not a Module. */
    VALUE cRedis = rb_define_class("Redis", rb_cObject);
    VALUE mXXH3 = rb_define_module_under(cRedis, "XXH3");
    rb_define_singleton_method(mXXH3, "_hexdigest", rb_xxh3_hexdigest, 1);
}
