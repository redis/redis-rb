# frozen_string_literal: true

class Redis
  # Pure-Ruby XXH3-64 (unseeded, default secret), matching the Redis server's DIGEST
  # command byte-for-byte. Ported directly, function-by-function, from the reference
  # implementation (https://github.com/Cyan4973/xxHash, v0.8.3 — the same version and
  # secret table the server itself vendors) rather than reimplemented from a description,
  # to avoid subtle per-input-length transcription bugs. Every private method below is
  # named after the upstream C function it mirrors, to keep that mapping checkable.
  #
  # Ships as plain Ruby, no native extension: the 128-bit multiply-and-fold XXH3 needs
  # throughout is the main source of complexity in a C port (no portable 128-bit integer
  # type), but it's trivial with Ruby's native arbitrary-precision integers — `lhs * rhs`
  # never overflows, so the "fold" is just splitting the product with a shift and mask.
  #
  # @example
  #   digest = Redis::XXH3.hexdigest("bar")
  #   redis.set("foo", "bar")
  #   redis.digest("foo") == digest # => true
  module XXH3
    MASK64 = (1 << 64) - 1
    MASK32 = 0xFFFFFFFF

    PRIME32_1 = 0x9E3779B1
    PRIME32_2 = 0x85EBCA77
    PRIME32_3 = 0xC2B2AE3D
    PRIME64_1 = 0x9E3779B185EBCA87
    PRIME64_2 = 0xC2B2AE3D27D4EB4F
    PRIME64_3 = 0x165667B19E3779F9
    PRIME64_4 = 0x85EBCA77C2B2AE63
    PRIME64_5 = 0x27D4EB2F165667C5
    PRIME_MX1 = 0x165667919E3779F9
    PRIME_MX2 = 0x9FB21C651E98DF25

    # XXH3_kSecret, verbatim. Not a cryptographic secret: it's a fixed, publicly-known
    # mixing constant from the open-source xxHash reference implementation (the same
    # bytes are in the Redis server's own open-source C source), not a per-installation
    # or per-key value — XXH3 is a non-cryptographic hash and makes no attempt to hide
    # this table. "Secret" is upstream's own name for it, not a claim of confidentiality.
    SECRET = [
      0xb8, 0xfe, 0x6c, 0x39, 0x23, 0xa4, 0x4b, 0xbe, 0x7c, 0x01, 0x81, 0x2c, 0xf7, 0x21, 0xad, 0x1c,
      0xde, 0xd4, 0x6d, 0xe9, 0x83, 0x90, 0x97, 0xdb, 0x72, 0x40, 0xa4, 0xa4, 0xb7, 0xb3, 0x67, 0x1f,
      0xcb, 0x79, 0xe6, 0x4e, 0xcc, 0xc0, 0xe5, 0x78, 0x82, 0x5a, 0xd0, 0x7d, 0xcc, 0xff, 0x72, 0x21,
      0xb8, 0x08, 0x46, 0x74, 0xf7, 0x43, 0x24, 0x8e, 0xe0, 0x35, 0x90, 0xe6, 0x81, 0x3a, 0x26, 0x4c,
      0x3c, 0x28, 0x52, 0xbb, 0x91, 0xc3, 0x00, 0xcb, 0x88, 0xd0, 0x65, 0x8b, 0x1b, 0x53, 0x2e, 0xa3,
      0x71, 0x64, 0x48, 0x97, 0xa2, 0x0d, 0xf9, 0x4e, 0x38, 0x19, 0xef, 0x46, 0xa9, 0xde, 0xac, 0xd8,
      0xa8, 0xfa, 0x76, 0x3f, 0xe3, 0x9c, 0x34, 0x3f, 0xf9, 0xdc, 0xbb, 0xc7, 0xc7, 0x0b, 0x4f, 0x1d,
      0x8a, 0x51, 0xe0, 0x4b, 0xcd, 0xb4, 0x59, 0x31, 0xc8, 0x9f, 0x7e, 0xc9, 0xd9, 0x78, 0x73, 0x64,
      0xea, 0xc5, 0xac, 0x83, 0x34, 0xd3, 0xeb, 0xc3, 0xc5, 0x81, 0xa0, 0xff, 0xfa, 0x13, 0x63, 0xeb,
      0x17, 0x0d, 0xdd, 0x51, 0xb7, 0xf0, 0xda, 0x49, 0xd3, 0x16, 0x55, 0x26, 0x29, 0xd4, 0x68, 0x9e,
      0x2b, 0x16, 0xbe, 0x58, 0x7d, 0x47, 0xa1, 0xfc, 0x8f, 0xf8, 0xb8, 0xd1, 0x7a, 0xd0, 0x31, 0xce,
      0x45, 0xcb, 0x3a, 0x8f, 0x95, 0x16, 0x04, 0x28, 0xaf, 0xd7, 0xfb, 0xca, 0xbb, 0x4b, 0x40, 0x7e
    ].pack("C*").freeze

    STRIPE_LEN = 64
    SECRET_CONSUME_RATE = 8
    SECRET_SIZE_MIN = 136
    MIDSIZE_MAX = 240
    MIDSIZE_STARTOFFSET = 3
    MIDSIZE_LASTOFFSET = 17
    SECRET_LASTACC_START = 7
    SECRET_MERGEACCS_START = 11

    # XXH3_INIT_ACC
    INIT_ACC = [PRIME32_3, PRIME64_1, PRIME64_2, PRIME64_3,
                PRIME64_4, PRIME32_2, PRIME64_5, PRIME32_1].freeze

    # Implementation details of the algorithm, not part of the public API — only
    # Redis::XXH3.hexdigest is meant to be used from outside this module.
    IMPLEMENTATION_CONSTANTS = %i[
      MASK64 MASK32 PRIME32_1 PRIME32_2 PRIME32_3 PRIME64_1 PRIME64_2 PRIME64_3
      PRIME64_4 PRIME64_5 PRIME_MX1 PRIME_MX2 SECRET STRIPE_LEN SECRET_CONSUME_RATE
      SECRET_SIZE_MIN MIDSIZE_MAX MIDSIZE_STARTOFFSET MIDSIZE_LASTOFFSET
      SECRET_LASTACC_START SECRET_MERGEACCS_START INIT_ACC
    ].freeze
    private_constant(*IMPLEMENTATION_CONSTANTS)
    private_constant :IMPLEMENTATION_CONSTANTS

    class << self
      # @param value [String, #to_s] the value to hash
      # @return [String] 16 lowercase hex characters
      def hexdigest(value)
        format("%016x", hash64(value.to_s.b))
      end

      private

      # XXH3_64bits()
      def hash64(input)
        len = input.bytesize
        if len <= 16
          len_0to16_64b(input, len)
        elsif len <= 128
          len_17to128_64b(input, len)
        elsif len <= MIDSIZE_MAX
          len_129to240_64b(input, len)
        else
          hash_long_64b(input, len)
        end
      end

      def read_le32(str, offset)
        str.unpack1("V", offset: offset)
      end

      def read_le64(str, offset)
        str.unpack1("Q<", offset: offset)
      end

      def rotl64(x, r)
        ((x << r) | (x >> (64 - r))) & MASK64
      end

      # XXH_swap64()
      def swap64(x)
        ((x << 56) & 0xff00000000000000) |
          ((x << 40) & 0x00ff000000000000) |
          ((x << 24) & 0x0000ff0000000000) |
          ((x << 8)  & 0x000000ff00000000) |
          ((x >> 8)  & 0x00000000ff000000) |
          ((x >> 24) & 0x0000000000ff0000) |
          ((x >> 40) & 0x000000000000ff00) |
          ((x >> 56) & 0x00000000000000ff)
      end

      # XXH3_mul128_fold64(): 64x64->128 multiply, then XOR-fold the two 64-bit halves.
      def mul128_fold64(lhs, rhs)
        product = lhs * rhs
        (product & MASK64) ^ (product >> 64)
      end

      def xorshift64(v, shift)
        (v ^ (v >> shift)) & MASK64
      end

      # XXH3_avalanche()
      def avalanche(h64)
        h64 = xorshift64(h64, 37)
        h64 = (h64 * PRIME_MX1) & MASK64
        xorshift64(h64, 32)
      end

      # XXH64_avalanche()
      def avalanche64(h)
        h ^= (h >> 33)
        h = (h * PRIME64_2) & MASK64
        h ^= (h >> 29)
        h = (h * PRIME64_3) & MASK64
        h ^= (h >> 32)
        h & MASK64
      end

      # XXH3_rrmxmx()
      def rrmxmx(h64, len)
        h64 ^= (rotl64(h64, 49) ^ rotl64(h64, 24))
        h64 = (h64 * PRIME_MX2) & MASK64
        h64 ^= ((h64 >> 35) + len)
        h64 = (h64 * PRIME_MX2) & MASK64
        xorshift64(h64, 28)
      end

      # --- 0-16 bytes: XXH3_len_0to16_64b and its sub-cases (seed is always 0) ---

      def len_0to16_64b(input, len)
        if len > 8
          len_9to16_64b(input, len)
        elsif len >= 4
          len_4to8_64b(input, len)
        elsif len > 0
          len_1to3_64b(input, len)
        else
          avalanche64(read_le64(SECRET, 56) ^ read_le64(SECRET, 64))
        end
      end

      # XXH3_len_1to3_64b()
      def len_1to3_64b(input, len)
        c1 = input.getbyte(0)
        c2 = input.getbyte(len >> 1)
        c3 = input.getbyte(len - 1)
        combined = (c1 << 16) | (c2 << 24) | c3 | (len << 8)
        bitflip = read_le32(SECRET, 0) ^ read_le32(SECRET, 4)
        avalanche64((combined ^ bitflip) & MASK64)
      end

      # XXH3_len_4to8_64b()
      def len_4to8_64b(input, len)
        input1 = read_le32(input, 0)
        input2 = read_le32(input, len - 4)
        bitflip = read_le64(SECRET, 8) ^ read_le64(SECRET, 16)
        input64 = (input2 + (input1 << 32)) & MASK64
        rrmxmx(input64 ^ bitflip, len)
      end

      # XXH3_len_9to16_64b()
      def len_9to16_64b(input, len)
        bitflip1 = read_le64(SECRET, 24) ^ read_le64(SECRET, 32)
        bitflip2 = read_le64(SECRET, 40) ^ read_le64(SECRET, 48)
        input_lo = read_le64(input, 0) ^ bitflip1
        input_hi = read_le64(input, len - 8) ^ bitflip2
        acc = (len + swap64(input_lo) + input_hi + mul128_fold64(input_lo, input_hi)) & MASK64
        avalanche(acc)
      end

      # --- 17-128 bytes: XXH3_len_17to128_64b ---

      # XXH3_mix16B()
      def mix16b(input, input_off, secret_off)
        input_lo = read_le64(input, input_off)
        input_hi = read_le64(input, input_off + 8)
        keyed_lo = input_lo ^ read_le64(SECRET, secret_off)
        keyed_hi = input_hi ^ read_le64(SECRET, secret_off + 8)
        mul128_fold64(keyed_lo, keyed_hi)
      end

      def len_17to128_64b(input, len)
        acc = (len * PRIME64_1) & MASK64
        if len > 32
          if len > 64
            if len > 96
              acc = (acc + mix16b(input, 48, 96)) & MASK64
              acc = (acc + mix16b(input, len - 64, 112)) & MASK64
            end
            acc = (acc + mix16b(input, 32, 64)) & MASK64
            acc = (acc + mix16b(input, len - 48, 80)) & MASK64
          end
          acc = (acc + mix16b(input, 16, 32)) & MASK64
          acc = (acc + mix16b(input, len - 32, 48)) & MASK64
        end
        acc = (acc + mix16b(input, 0, 0)) & MASK64
        acc = (acc + mix16b(input, len - 16, 16)) & MASK64
        avalanche(acc)
      end

      # --- 129-240 bytes: XXH3_len_129to240_64b ---

      def len_129to240_64b(input, len)
        acc = (len * PRIME64_1) & MASK64
        nb_rounds = len / 16
        8.times { |i| acc = (acc + mix16b(input, 16 * i, 16 * i)) & MASK64 }
        acc = avalanche(acc)
        acc_end = mix16b(input, len - 16, SECRET_SIZE_MIN - MIDSIZE_LASTOFFSET)
        (8...nb_rounds).each do |i|
          acc_end = (acc_end + mix16b(input, 16 * i, (16 * (i - 8)) + MIDSIZE_STARTOFFSET)) & MASK64
        end
        avalanche((acc + acc_end) & MASK64)
      end

      # --- >240 bytes: XXH3_hashLong_64b_default and its accumulator loop ---

      def hash_long_64b(input, len)
        acc = INIT_ACC.dup
        hash_long_internal_loop(acc, input, len)
        finalize_long_64b(acc, len)
      end

      # XXH3_hashLong_internal_loop()
      def hash_long_internal_loop(acc, input, len)
        secret_size = SECRET.bytesize
        nb_stripes_per_block = (secret_size - STRIPE_LEN) / SECRET_CONSUME_RATE
        block_len = STRIPE_LEN * nb_stripes_per_block
        nb_blocks = (len - 1) / block_len

        nb_blocks.times do |n|
          accumulate(acc, input, n * block_len, nb_stripes_per_block)
          scramble_acc(acc, secret_size - STRIPE_LEN)
        end

        nb_stripes = ((len - 1) - (block_len * nb_blocks)) / STRIPE_LEN
        accumulate(acc, input, nb_blocks * block_len, nb_stripes)

        # last stripe
        accumulate_512(acc, input, len - STRIPE_LEN, secret_size - STRIPE_LEN - SECRET_LASTACC_START)
      end

      # XXH3_accumulate_scalar()
      def accumulate(acc, input, input_off, nb_stripes)
        nb_stripes.times do |n|
          accumulate_512(acc, input, input_off + (n * STRIPE_LEN), n * SECRET_CONSUME_RATE)
        end
      end

      # XXH3_accumulate_512_scalar() / XXH3_scalarRound(): mutates `acc` (8 lanes) in place;
      # lane order matters since each round writes both acc[lane] and acc[lane ^ 1].
      def accumulate_512(acc, input, input_off, secret_off)
        8.times do |lane|
          data_val = read_le64(input, input_off + (lane * 8))
          data_key = data_val ^ read_le64(SECRET, secret_off + (lane * 8))
          acc[lane ^ 1] = (acc[lane ^ 1] + data_val) & MASK64
          acc[lane] = (((data_key & MASK32) * ((data_key >> 32) & MASK32)) + acc[lane]) & MASK64
        end
      end

      # XXH3_scrambleAcc_scalar() / XXH3_scalarScrambleRound()
      def scramble_acc(acc, secret_off)
        8.times do |lane|
          key64 = read_le64(SECRET, secret_off + (lane * 8))
          acc64 = xorshift64(acc[lane], 47)
          acc64 ^= key64
          acc[lane] = (acc64 * PRIME32_1) & MASK64
        end
      end

      # XXH3_finalizeLong_64b()
      def finalize_long_64b(acc, len)
        merge_accs(acc, SECRET_MERGEACCS_START, (len * PRIME64_1) & MASK64)
      end

      # XXH3_mergeAccs() / XXH3_mix2Accs()
      def merge_accs(acc, secret_off, start)
        result = start
        4.times do |i|
          lo = acc[2 * i] ^ read_le64(SECRET, secret_off + (16 * i))
          hi = acc[(2 * i) + 1] ^ read_le64(SECRET, secret_off + (16 * i) + 8)
          result = (result + mul128_fold64(lo, hi)) & MASK64
        end
        avalanche(result)
      end
    end
  end
end
