# Deflate

Pure Elixir implementation of DEFLATE (RFC 1951) and zlib (RFC 1950) decompression with **exact byte consumption tracking**.

[![Hex.pm](https://img.shields.io/hexpm/v/deflate.svg)](https://hex.pm/packages/deflate)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/deflate)

## Why This Library?

Erlang's `:zlib` module is fast (it's a C NIF), but it has a critical limitation: **you can't determine exactly how many bytes were consumed** when decompressing a stream.

This matters when parsing binary formats with concatenated compressed streams, like:

- **Git pack files** - multiple zlib-compressed objects back-to-back
- **PNG chunks** - IDAT chunks contain zlib streams
- **PDF streams** - FlateDecode compressed content
- **ZIP files** - DEFLATE compressed entries

```elixir
# With :zlib - no way to know where stream 1 ends and stream 2 begins
:zlib.uncompress(concatenated_streams)  # Returns data, but how many bytes consumed?

# With Deflate - exact byte tracking
{:ok, data1, bytes_consumed} = Deflate.inflate(concatenated_streams)
remaining = binary_part(concatenated_streams, bytes_consumed, byte_size(concatenated_streams) - bytes_consumed)
{:ok, data2, _} = Deflate.inflate(remaining)
```

## Why Not Use Existing Libraries?

There are several compression libraries on Hex. Here's why we built this one:

| Feature | deflate | [ezlib](https://hex.pm/packages/ezlib) | [compresso](https://hex.pm/packages/compresso) | [zip_stream](https://hex.pm/packages/zip_stream) |
|---------|---------|-------|-----------|------------|
| **Byte consumption tracking** | ✅ | ❌ | ❌ | ❌ |
| **Chunked network input** | ✅ | ❌ | ❌ | ❌ |
| **Pure Elixir (no NIFs)** | ✅ | ❌ (C NIF) | ❌ (wraps :zlib) | ❌ (wraps :zlib) |
| **Streaming output** | ✅ | ❌ | ❌ | ✅ |

**The core problem:** All existing libraries wrap `:zlib` or use C NIFs. None of them tell you how many compressed bytes were consumed. This makes it impossible to parse formats with concatenated streams.

- **ezlib** - C NIF bindings to zlib. Fast, but no byte tracking, and adds native dependency.
- **compresso** - Gleam package wrapping :zlib. No byte tracking.
- **zip_stream** - Great for ZIP files specifically, but uses :zlib internally. No byte tracking for raw streams.

We needed byte tracking for [SourceKeep](https://github.com/jtwebman/sourcekeep) (a git hosting platform) to parse git pack files. The only solution was implementing DEFLATE from scratch in pure Elixir.

## Installation

Add `deflate` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:deflate, "~> 1.0"}
  ]
end
```

## Usage

### Decompress zlib-wrapped data

```elixir
# Standard zlib format (2-byte header + deflate + 4-byte adler32)
compressed = :zlib.compress("hello world")

{:ok, "hello world", bytes_consumed} = Deflate.inflate(compressed)
```

### Decompress raw DEFLATE data

```elixir
# Raw DEFLATE without zlib wrapper
{:ok, data, bytes_consumed} = Deflate.inflate_raw(raw_deflate_data)
```

### Parse concatenated streams (e.g., git pack files)

```elixir
defmodule GitPack do
  def parse_objects(data, count, objects \\ [])

  def parse_objects(_data, 0, objects), do: Enum.reverse(objects)

  def parse_objects(data, remaining, objects) do
    {type, size, header_len} = parse_object_header(data)
    rest = binary_part(data, header_len, byte_size(data) - header_len)

    # Deflate tells us exactly how many compressed bytes were consumed
    {:ok, content, consumed} = Deflate.inflate(rest)

    after_object = binary_part(rest, consumed, byte_size(rest) - consumed)
    parse_objects(after_object, remaining - 1, [{type, content} | objects])
  end
end
```

### Streaming decompression (hash/store without full memory)

For large files or when you want to compute hashes without holding the entire decompressed content in memory, use the streaming API:

```elixir
# Stream directly to SHA-256 hasher
hasher = :crypto.hash_init(:sha256)

{:ok, final_hasher, bytes_consumed} = Deflate.inflate_stream(compressed, hasher, fn chunk, h ->
  :crypto.hash_update(h, chunk)
end)

hash = :crypto.hash_final(final_hasher)
```

```elixir
# Stream to file
{:ok, file} = File.open("output.bin", [:write, :binary])

{:ok, _, _} = Deflate.inflate_stream(compressed, nil, fn chunk, _ ->
  IO.binwrite(file, chunk)
  nil
end)

File.close(file)
```

**Note:** `:zlib` cannot do streaming with byte tracking at all. It either gives you:
- Streaming decompression (`:zlib.inflateInit/1` + `:zlib.inflate/2`) but no way to know where the stream ends
- Full decompression (`:zlib.uncompress/1`) but no byte tracking

This library provides both streaming output AND exact byte consumption tracking.

### Chunked input (for network streams)

When data arrives in chunks (e.g., from SSH or HTTP streaming), use the stateful decoder:

```elixir
alias Deflate.Decoder

# Initialize decoder
{:ok, decoder} = Decoder.new()

# Feed chunks as they arrive from network
{:ok, output1, decoder} = Decoder.decode(decoder, packet1)
{:ok, output2, decoder} = Decoder.decode(decoder, packet2)
{:ok, output3, decoder} = Decoder.decode(decoder, packet3)

# When stream ends, get final results
{:done, <<>>, bytes_consumed} = Decoder.finish(decoder)
```

The decoder maintains state between chunks, handling all the complexity of:
- Bit-level boundaries (Huffman codes can span byte boundaries)
- Back-references that cross chunk boundaries
- Dynamic Huffman table parsing across chunks

This is essential for protocols like git-over-SSH where pack data arrives in network packets.

## Performance

### The Honest Numbers

For decompression speed, `:zlib` (C NIF) is faster:

| Input Type | Deflate (Elixir) | :zlib (C NIF) | Difference |
|------------|------------------|---------------|------------|
| Random 100KB | **13x faster** | - | Stored blocks, minimal decoding |
| Text 100KB | 6x slower | - | ~177 μs difference |
| Text 10KB | 30x slower | - | ~149 μs difference |

### Why It Doesn't Matter

Those ratios sound scary, but look at the **absolute times**:

| Input | Deflate | :zlib | Actual Difference |
|-------|---------|-------|-------------------|
| Text 100KB | 213 μs | 36 μs | **0.18 ms** |
| Text 10KB | 154 μs | 5 μs | **0.15 ms** |
| Text 100B | 102 μs | 2 μs | **0.10 ms** |

In real-world applications, decompression is rarely the bottleneck:

```
Typical file processing pipeline:
  Decompress:     ~200 μs  (this library)
  Parse content:  ~5,000 μs  (JSON/AST/etc)
  Database I/O:   ~2,000 μs
  Network I/O:    ~10,000+ μs
  ─────────────────────────────
  Decompression: ~1% of total time
```

**Use this library when you need byte tracking. Use `:zlib` when you need raw speed and don't care about consumption tracking.**

## Features

- **Pure Elixir** - No NIFs, no ports, works everywhere BEAM runs
- **Exact byte tracking** - Know precisely how many bytes were consumed
- **Streaming output** - Decompress to callbacks for hashing/storage without full memory
- **Chunked input** - Feed data as it arrives from network (SSH, HTTP streams)
- **Full DEFLATE support** - Stored, fixed Huffman, and dynamic Huffman blocks
- **zlib wrapper support** - Handles standard zlib header/trailer
- **Zero dependencies** - Only uses Erlang/OTP standard library

## Limitations

- **Decompression only** - This library does not compress data (use `:zlib.compress/1` for that)
- **No preset dictionaries** - zlib preset dictionary feature not supported

## How It Works

The library implements:

1. **zlib header parsing** (RFC 1950) - CMF, FLG bytes, optional dict, Adler-32 checksum
2. **DEFLATE decompression** (RFC 1951):
   - Stored blocks (type 0) - uncompressed data
   - Fixed Huffman (type 1) - predefined code tables
   - Dynamic Huffman (type 2) - custom code tables in stream
3. **Bit-level reading** - LSB-first bit extraction with precise tracking
4. **LZ77 back-references** - Copy from sliding window with overlap handling

Compile-time generated lookup tables provide O(1) Huffman symbol decoding.

## License

MIT License - see [LICENSE](LICENSE) file.
